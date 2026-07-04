import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// The **streaming** on-device transcoder (roadmap M-A). Where `FFmpegRemuxer` stream-copies an exotic
/// container into fragmented MP4, this one *re-encodes* the video (decode → libswscale NV12 →
/// VideoToolbox `h264_videotoolbox`) so files Apple can't decode at all — VP9, AV1 with no HW decoder,
/// 10-bit 4:2:2/4:4:4 HEVC — can still play on-device instead of loading the Stash server. It emits a
/// growing **fragmented MP4** through a custom output `AVIOContext` (never seeks back to patch a moov),
/// which `FMP4Index` + `LoopbackServer` serve to AVPlayer as byte-range HLS — identical delivery to
/// `LocalRemuxStream`, only the production step differs.
///
/// It fuses the two proven halves: the read-ahead / range-request input AVIO + playhead pacing +
/// seek-by-reinit + interrupt/abort machinery from `FFmpegRemuxer`, and the hardware decode→scale→encode
/// inner loop from `FFmpegTranscoder`. Audio is stream-copied when the source codec is MP4-muxable
/// (AAC/AC3/EAC3/MP3/ALAC); Opus/Vorbis → AAC re-encode is the immediate follow-up (Stage 1b) — until
/// then such tracks are dropped (video still plays).
///
/// Target codec is fixed to **H.264 (avc1)**: the most broadly decodable output over loopback HLS, and it
/// sidesteps the hvc1/hev1 sample-entry tagging pitfalls that HEVC-in-fragmented-MP4 carries.
final class FFmpegStreamTranscoder: @unchecked Sendable {
    // MARK: Input (read) state — mirrors FFmpegRemuxer / FFmpegSource.
    private let url: URL
    private let session: URLSession
    private var offset: Int64 = 0
    private var size: Int64 = -1
    private let isLocalFile: Bool
    private var localHandle: FileHandle?
    private let ioBufferSize = 1 << 18            // 256 KB AVIO buffers
    private var cacheStart: Int64 = -1
    private var cache = Data()
    private let readAhead = 1 << 22               // 4 MB per upstream fetch

    // MARK: Output (write) state — growing fragmented-MP4 temp file via custom write AVIO.
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private(set) var bytesWritten = 0

    // MARK: Transcode target.
    private let maxDimension: Int?                // longest-edge cap (nil = keep source), e.g. 1920 for 1080p
    private let quality: TranscodeQuality
    /// Audio codecs an iPhone can carry in MP4 untouched — copied through with no re-encode.
    private static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    // MARK: Pacing + seek (from FFmpegRemuxer).
    private let startTime: Double
    private let playhead: (@Sendable () -> Double)?
    private let paceLeadSeconds: Double = 60      // a re-encode is slow; keep a modest lead over the playhead
    private let paceThresholdBytes: Int64 = 80 << 20   // pace sources larger than ~80 MB

    // MARK: Thread-safe progress read by the loopback server / index from their own thread.
    private let progressLock = NSLock()
    private var finishedFlag = false
    private var abortedFlag = false
    private var producedMediaSeconds = 0.0
    var producedBytes: Int { progressLock.withLock { bytesWritten } }
    var isFinished: Bool { progressLock.withLock { finishedFlag } }
    var producedSeconds: Double { progressLock.withLock { producedMediaSeconds } }
    private var isAborted: Bool { progressLock.withLock { abortedFlag } }

    /// Wall-clock deadline the interrupt callback watches, so wedged IO can't hang the pipeline.
    fileprivate var deadline: CFAbsoluteTime = 0

    /// Abort promptly (playback stopped / stream torn down).
    func abort() {
        progressLock.withLock { abortedFlag = true }
        deadline = 1
    }

    // Macros the Swift importer doesn't surface (identical values to FFmpegRemuxer / FFmpegTranscoder).
    private let averrorEOF: Int32 = -541478725
    private let averrorExit: Int32 = -1414092869
    private let averrorEAGAIN: Int32 = -35
    private let avseekSize: Int32 = 0x10000
    private let avseekForce: Int32 = 0x20000
    private let avfmtFlagCustomIO: Int32 = 0x0080
    private let avfmtGlobalHeader: Int32 = 0x0040
    private let codecFlagGlobalHeader: Int32 = 1 << 22
    private let swsBilinear: Int32 = 2
    private let avNoPTS: Int64 = Int64.min

    private final class Box: @unchecked Sendable {
        var data: Data?
        var total: Int64?
        var error: Error?
    }

    init(url: URL, fileURL: URL, startTime: Double = 0, maxDimension: Int?,
         quality: TranscodeQuality = .medium, playhead: (@Sendable () -> Double)? = nil) {
        self.url = url
        self.fileURL = fileURL
        self.startTime = startTime
        self.maxDimension = maxDimension
        self.quality = quality
        self.playhead = playhead
        self.isLocalFile = url.isFileURL
        self.localHandle = url.isFileURL ? try? FileHandle(forReadingFrom: url) : nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    deinit {
        session.invalidateAndCancel()
        try? localHandle?.close()
    }

    /// Run the full streaming transcode to the temp file; returns a short human summary (or error string).
    /// The interrupt deadline bounds the work so the detached task always returns.
    func transcodeSummary() async -> String {
        await withCheckedContinuation { continuation in
            // A dedicated thread, not the cooperative pool: the decode/encode loop is a long, fully
            // blocking C call that would otherwise starve a shared executor thread.
            Thread.detachNewThread { [self] in
                continuation.resume(returning: runSync())
            }
        }
    }

    // MARK: - Blocking pipeline (own thread)

    private func runSync() -> String {
        defer { progressLock.withLock { finishedFlag = true } }
        deadline = CFAbsoluteTimeGetCurrent() + 30   // generous; bumped forward on every bit of progress
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        if fileHandle == nil { return "temp file open failed" }
        defer { try? fileHandle?.close() }

        // --- Input: open through a custom read/seek AVIO (range requests / local file) ---
        guard let inBuffer = av_malloc(ioBufferSize) else { return "in alloc failed" }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let readAVIO = avio_alloc_context(
            inBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 0, opaque,
            sxRead, nil, sxSeek
        ) else { av_free(inBuffer); return "in avio alloc failed" }

        var input = avformat_alloc_context()
        if let input {
            input.pointee.pb = readAVIO
            input.pointee.flags |= avfmtFlagCustomIO
            input.pointee.interrupt_callback.callback = sxInterrupt
            input.pointee.interrupt_callback.opaque = opaque
        }
        if avformat_open_input(&input, nil, nil, nil) < 0 { freeAVIO(readAVIO); return "open failed" }
        _ = avformat_find_stream_info(input, nil)
        defer { cleanupInput(&input, readAVIO) }

        // --- Locate + open the video decoder (prefer VideoToolbox HW; fall back to multi-thread SW) ---
        var vDecCodec: UnsafePointer<AVCodec>?
        let vIdx = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, &vDecCodec, 0)
        guard vIdx >= 0, let vDecCodec, let vInStream = input!.pointee.streams[Int(vIdx)],
              let vCodecpar = vInStream.pointee.codecpar else { return "no video stream" }
        let srcName = String(cString: avcodec_get_name(vCodecpar.pointee.codec_id))

        guard let vDecCtx = avcodec_alloc_context3(vDecCodec),
              avcodec_parameters_to_context(vDecCtx, vCodecpar) >= 0 else { return "decoder alloc failed" }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vDecCtx; avcodec_free_context(&p) }
        vDecCtx.pointee.thread_count = 0
        var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            vDecCtx.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
            vDecCtx.pointee.get_format = sxGetHWFormat
        }
        defer { if hwDeviceCtx != nil { av_buffer_unref(&hwDeviceCtx) } }
        guard avcodec_open2(vDecCtx, vDecCodec, nil) >= 0 else { return "decoder open failed (\(srcName))" }

        // --- Sizing + frame rate + bitrate ---
        let srcW = Int(vCodecpar.pointee.width), srcH = Int(vCodecpar.pointee.height)
        let outSize = VideoTranscoder.outputSize(naturalSize: CGSize(width: srcW, height: srcH),
                                                 maxDimension: maxDimension)
        var fr = vInStream.pointee.avg_frame_rate
        if fr.num <= 0 || fr.den <= 0 { fr = vInStream.pointee.r_frame_rate }
        if fr.num <= 0 || fr.den <= 0 { fr = AVRational(num: 30, den: 1) }
        let fps = av_q2d(fr) > 0 ? av_q2d(fr) : 30
        let bitrate = VideoTranscoder.videoBitrate(width: outSize.width, height: outSize.height,
                                                   fps: fps, quality: quality, codec: .h264)

        // --- Audio: copy when MP4-muxable, else drop (Stage 1a; AAC re-encode is Stage 1b) ---
        var aInStream: UnsafeMutablePointer<AVStream>?
        let aIdx = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        var audioNote = "no audio"
        if aIdx >= 0, let s = input!.pointee.streams[Int(aIdx)], let apar = s.pointee.codecpar {
            let name = String(cString: avcodec_get_name(apar.pointee.codec_id))
            if Self.copyableAudio.contains(name) { aInStream = s; audioNote = "audio \(name) (copy)" }
            else { audioNote = "audio \(name) dropped (AAC re-encode pending)" }
        }

        // Stage diagnostic: exactly what came in and how we're decoding it. This is the line that tells us
        // *why* an HEVC/exotic file black-screens — source codec, pixel format (10-bit / 4:2:2 shows here),
        // and whether the VideoToolbox HW decoder actually attached vs. falling back to software.
        let container = input?.pointee.iformat.map { String(cString: $0.pointee.name) } ?? "?"
        let srcPix = av_get_pix_fmt_name(AVPixelFormat(rawValue: vCodecpar.pointee.format)).map { String(cString: $0) } ?? "?"
        // NB: this tier re-encodes to 8-bit H.264, so an HDR source is tonemapped down to SDR here — logging
        // the source transfer function makes that loss visible (only exotic codecs Apple can't decode hit
        // this path; native HDR HEVC direct-plays/remuxes and keeps its HDR).
        let srcHDR: String
        let srcTrc = vCodecpar.pointee.color_trc
        if srcTrc == AVCOL_TRC_SMPTE2084 { srcHDR = "HDR-PQ→SDR" }
        else if srcTrc == AVCOL_TRC_ARIB_STD_B67 { srcHDR = "HDR-HLG→SDR" }
        else { srcHDR = "SDR" }
        RemoteLog.shared.event("⚙︎ transcode-in", [
            ("codec", srcName), ("container", container), ("src", "\(srcW)×\(srcH)"),
            ("pix", srcPix), ("hdr", srcHDR), ("hwdec", hwDeviceCtx != nil ? "vt" : "sw"),
            ("out", "\(outSize.width)×\(outSize.height)"), ("fps", String(format: "%.1f", fps)),
            ("kbps", bitrate / 1000), ("audio", audioNote), ("start", Int(startTime))
        ])

        // --- Output: MP4 muxer → custom write AVIO (fragmented, forward-only) ---
        var outFmtOpt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outFmtOpt, nil, "mp4", nil) >= 0,
              let outFmt = outFmtOpt else { return "out alloc failed" }
        guard let outBuffer = av_malloc(ioBufferSize) else { avformat_free_context(outFmt); return "out alloc failed" }
        guard let writeAVIO = avio_alloc_context(
            outBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 1, opaque,
            nil, sxWrite, nil
        ) else { av_free(outBuffer); avformat_free_context(outFmt); return "out avio alloc failed" }
        outFmt.pointee.pb = writeAVIO
        defer { cleanupOutput(outFmt, writeAVIO) }

        // --- H.264 VideoToolbox encoder ---
        guard let encCodec = avcodec_find_encoder_by_name("h264_videotoolbox"),
              let vEncCtx = avcodec_alloc_context3(encCodec) else { return "h264_videotoolbox unavailable" }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vEncCtx; avcodec_free_context(&p) }
        vEncCtx.pointee.width = Int32(outSize.width)
        vEncCtx.pointee.height = Int32(outSize.height)
        vEncCtx.pointee.pix_fmt = AV_PIX_FMT_NV12
        vEncCtx.pointee.time_base = av_inv_q(fr)
        vEncCtx.pointee.framerate = fr
        vEncCtx.pointee.bit_rate = Int64(bitrate)
        vEncCtx.pointee.gop_size = Int32(max(2, Int(fps * 2)))   // keyframe every ~2s → ~2s fMP4 fragments
        vEncCtx.pointee.sample_aspect_ratio = vDecCtx.pointee.sample_aspect_ratio
        // Fragmented MP4 (empty_moov) needs the codec params in the init segment's avcC, so the encoder
        // must emit a global header (extradata) rather than in-band SPS/PPS — else AVPlayer gets no
        // decoder config and the video won't play.
        if outFmt.pointee.oformat.pointee.flags & avfmtGlobalHeader != 0 {
            vEncCtx.pointee.flags |= codecFlagGlobalHeader
        }
        av_opt_set(vEncCtx.pointee.priv_data, "realtime", "true", 0)
        guard avcodec_open2(vEncCtx, encCodec, nil) >= 0 else { return "encoder open failed" }

        guard let vOutStream = avformat_new_stream(outFmt, nil),
              avcodec_parameters_from_context(vOutStream.pointee.codecpar, vEncCtx) >= 0 else {
            return "video out stream failed"
        }
        vOutStream.pointee.codecpar.pointee.codec_tag = 0   // let the MP4 muxer assign avc1
        vOutStream.pointee.time_base = vEncCtx.pointee.time_base

        var aOutStream: UnsafeMutablePointer<AVStream>?
        if let aInStream {
            if let s = avformat_new_stream(outFmt, nil),
               avcodec_parameters_copy(s.pointee.codecpar, aInStream.pointee.codecpar) >= 0 {
                s.pointee.codecpar.pointee.codec_tag = 0
                aOutStream = s
            }
        }

        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0)
        let headerResult = avformat_write_header(outFmt, &options)
        av_dict_free(&options)
        if headerResult < 0 { return "write_header failed" }

        // --- Seek-by-reinit: jump the input near the target keyframe before transcoding ---
        if startTime > 0 {
            let tb = vInStream.pointee.time_base
            let target = tb.num > 0 ? Int64(startTime * Double(tb.den) / Double(tb.num)) : 0
            av_seek_frame(input, Int32(vIdx), target, 1 /* AVSEEK_FLAG_BACKWARD */)
            avcodec_flush_buffers(vDecCtx)
        }

        // --- Transcode loop ---
        var sws: UnsafeMutablePointer<SwsContext>?
        defer { if sws != nil { sws_freeContext(sws) } }
        let pkt = av_packet_alloc()
        let encPkt = av_packet_alloc()
        let decFrame = av_frame_alloc()
        defer {
            var a: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&a)
            var b: UnsafeMutablePointer<AVPacket>? = encPkt; av_packet_free(&b)
            var f: UnsafeMutablePointer<AVFrame>? = decFrame; av_frame_free(&f)
        }

        var tsShiftSeconds = -1.0            // set from the first timestamped packet after seek (zero-basing)
        var frames = 0
        var encError = false
        var loggedFirstFrame = false

        // Drain the encoder into the muxer.
        func drainEncoder(_ frame: UnsafeMutablePointer<AVFrame>?) -> Bool {
            guard avcodec_send_frame(vEncCtx, frame) >= 0 else { return false }
            while true {
                let r = avcodec_receive_packet(vEncCtx, encPkt)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { return false }
                encPkt!.pointee.stream_index = vOutStream.pointee.index
                av_packet_rescale_ts(encPkt, vEncCtx.pointee.time_base, vOutStream.pointee.time_base)
                encPkt!.pointee.pos = -1
                if av_interleaved_write_frame(outFmt, encPkt) < 0 { return false }
            }
            return true
        }

        // Decode a video packet, scale to NV12, feed the encoder (zero-based from the seek point).
        func decodeAndEncode(_ inputPkt: UnsafeMutablePointer<AVPacket>?) -> Bool {
            guard avcodec_send_packet(vDecCtx, inputPkt) >= 0 else { return true }
            while true {
                let r = avcodec_receive_frame(vDecCtx, decFrame)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { return false }

                // VideoToolbox frame is a GPU surface → copy down to a CPU NV12 frame we can scale/encode.
                let usingHW = decFrame!.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
                var transferred: UnsafeMutablePointer<AVFrame>?
                defer { if transferred != nil { av_frame_free(&transferred) } }
                let src: UnsafeMutablePointer<AVFrame>?
                if usingHW {
                    transferred = av_frame_alloc()
                    guard av_hwframe_transfer_data(transferred, decFrame, 0) >= 0 else { return false }
                    src = transferred
                } else {
                    src = decFrame
                }

                let sW = Int(src!.pointee.width), sH = Int(src!.pointee.height)
                let srcFmt = AVPixelFormat(rawValue: src!.pointee.format)
                let best = decFrame!.pointee.best_effort_timestamp

                // First decoded frame proves the decoder is emitting pixels (not silently stalling) and
                // reveals the real post-transfer format we're about to scale — the tell for the "black
                // video" HEVC cases where decode succeeds but the surface never becomes CPU-readable NV12.
                if !loggedFirstFrame {
                    loggedFirstFrame = true
                    let fmtName = av_get_pix_fmt_name(srcFmt).map { String(cString: $0) } ?? "?"
                    RemoteLog.shared.event("⚙︎ transcode-frame1", [
                        ("path", usingHW ? "hw→cpu" : "sw"), ("dims", "\(sW)×\(sH)"), ("pix", fmtName)
                    ])
                }

                var scaled: UnsafeMutablePointer<AVFrame>?
                defer { if scaled != nil { av_frame_free(&scaled) } }
                let encodeFrame: UnsafeMutablePointer<AVFrame>?
                if srcFmt == AV_PIX_FMT_NV12, sW == outSize.width, sH == outSize.height {
                    encodeFrame = src
                } else {
                    if sws == nil {
                        sws = sws_getContext(Int32(sW), Int32(sH), srcFmt,
                                             Int32(outSize.width), Int32(outSize.height), AV_PIX_FMT_NV12,
                                             swsBilinear, nil, nil, nil)
                        guard sws != nil else { return false }
                    }
                    scaled = av_frame_alloc()
                    scaled!.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
                    scaled!.pointee.width = Int32(outSize.width)
                    scaled!.pointee.height = Int32(outSize.height)
                    guard av_frame_get_buffer(scaled, 0) >= 0, sws_scale_frame(sws, scaled, src) >= 0 else {
                        return false
                    }
                    encodeFrame = scaled
                }

                // Zero-base the presentation time from the seek point (so the served stream starts at 0).
                if best != avNoPTS {
                    let sec = Double(best) * av_q2d(vInStream.pointee.time_base)
                    if startTime > 0, tsShiftSeconds < 0 { tsShiftSeconds = sec }
                    let adj = (startTime > 0 && tsShiftSeconds >= 0) ? sec - tsShiftSeconds : sec
                    if adj < -0.001 { av_frame_unref(decFrame); continue }   // pre-roll before the seek point
                    let step = av_q2d(vEncCtx.pointee.time_base)
                    encodeFrame!.pointee.pts = step > 0 ? Int64((max(0, adj) / step).rounded()) : Int64(frames)
                    progressLock.withLock { producedMediaSeconds = max(0, adj) }
                } else {
                    encodeFrame!.pointee.pts = Int64(frames)
                }
                if !drainEncoder(encodeFrame) { return false }
                av_frame_unref(decFrame)
                frames += 1
                if playhead != nil { deadline = CFAbsoluteTimeGetCurrent() + 30 }
            }
            return true
        }

        readLoop: while !isAborted {
            // Pace: don't race ahead of the playhead on a large source (a re-encode is expensive).
            if let playhead, size >= paceThresholdBytes {
                while !isAborted, producedSeconds - playhead() > paceLeadSeconds {
                    deadline = CFAbsoluteTimeGetCurrent() + 30
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if isAborted { break }
            }
            let r = av_read_frame(input, pkt)
            if r < 0 { break }   // EOF or interrupt
            deadline = CFAbsoluteTimeGetCurrent() + 30
            let inIdx = Int(pkt!.pointee.stream_index)
            if inIdx == Int(vIdx) {
                if !decodeAndEncode(pkt) { encError = true; av_packet_unref(pkt); break readLoop }
            } else if let aOutStream, inIdx == Int(aIdx), let aInStream {
                // Straight audio copy: zero-base to match the video, rescale to the output time base.
                let tb = aInStream.pointee.time_base
                if startTime > 0, tsShiftSeconds >= 0 {
                    let shift = av_q2d(tb) > 0 ? Int64(tsShiftSeconds / av_q2d(tb)) : 0
                    if pkt!.pointee.pts != avNoPTS { pkt!.pointee.pts -= shift }
                    if pkt!.pointee.dts != avNoPTS { pkt!.pointee.dts -= shift }
                    if pkt!.pointee.dts != avNoPTS, pkt!.pointee.dts < 0 { av_packet_unref(pkt); continue }
                }
                av_packet_rescale_ts(pkt, tb, aOutStream.pointee.time_base)
                pkt!.pointee.stream_index = aOutStream.pointee.index
                pkt!.pointee.pos = -1
                _ = av_interleaved_write_frame(outFmt, pkt)
            }
            av_packet_unref(pkt)
        }

        let aborted = isAborted
        if !aborted, !encError {
            _ = decodeAndEncode(nil)   // flush decoder
            _ = drainEncoder(nil)      // flush encoder
            _ = av_write_trailer(outFmt)
        }
        let status = aborted ? "aborted" : encError ? "encode error" : "done"
        // Final tally: bytes actually muxed is the decisive signal for "video disappeared after transcode".
        // frames>0 but bytes≈0 ⇒ the muxer never emitted the init segment (avcC/decoder config missing);
        // bytes>0 but black on screen ⇒ tagging/config, not production. Either way this line disambiguates.
        RemoteLog.shared.event("⚙︎ transcode-out", [
            ("status", status), ("frames", frames), ("mediaSec", String(format: "%.1f", producedSeconds)),
            ("bytes", producedBytes), ("audio", audioNote)
        ])
        return "h264 \(outSize.width)×\(outSize.height) · \(frames) frames · \(audioNote) · \(status)"
    }

    // MARK: - Cleanup

    private func cleanupInput(_ input: inout UnsafeMutablePointer<AVFormatContext>?, _ avio: UnsafeMutablePointer<AVIOContext>) {
        avformat_close_input(&input)
        freeAVIO(avio)
    }
    private func cleanupOutput(_ output: UnsafeMutablePointer<AVFormatContext>, _ avio: UnsafeMutablePointer<AVIOContext>) {
        avformat_free_context(output)
        freeAVIO(avio)
    }
    private func freeAVIO(_ avio: UnsafeMutablePointer<AVIOContext>) {
        let buffer = avio.pointee.buffer
        var ctx: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&ctx)
        if let buffer { av_free(buffer) }
    }

    // MARK: - AVIO callbacks (synchronous, on this transcode's thread)

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        let want = Int(count)
        if cacheStart >= 0, offset >= cacheStart, offset < cacheStart + Int64(cache.count) {
            let from = Int(offset - cacheStart)
            let n = min(want, cache.count - from)
            cache.withUnsafeBytes { raw in
                buffer.update(from: raw.baseAddress!.advanced(by: from).assumingMemoryBound(to: UInt8.self), count: n)
            }
            offset += Int64(n)
            return Int32(n)
        }
        if isLocalFile {
            guard let handle = localHandle else { return averrorEOF }
            do {
                try handle.seek(toOffset: UInt64(max(0, offset)))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { return averrorEOF }
                let n = min(data.count, want)
                data.copyBytes(to: buffer, count: n)
                offset += Int64(n)
                return Int32(n)
            } catch { return -5 }
        }
        var end = offset + Int64(max(want, readAhead)) - 1
        if size >= 0 { end = min(end, size - 1) }
        guard end >= offset else { return averrorEOF }
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if isAborted { return averrorExit }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: request) { data, response, err in
                box.data = data; box.total = Self.totalLength(from: response); box.error = err
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()
            if let total = box.total { size = total }
            if let data = box.data, !data.isEmpty {
                cache = data; cacheStart = offset
                let n = min(data.count, want)
                data.copyBytes(to: buffer, count: n)
                offset += Int64(n)
                return Int32(n)
            }
            if box.error == nil { return averrorEOF }
            if attempt < maxAttempts - 1 {
                for _ in 0..<10 { if isAborted { return averrorExit }; Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        return -5
    }

    fileprivate func seek(to target: Int64, whence: Int32) -> Int64 {
        if whence & avseekSize != 0 { return ensureSize() }
        switch whence & ~avseekForce {
        case Int32(SEEK_SET): offset = target
        case Int32(SEEK_CUR): offset += target
        case Int32(SEEK_END): offset = ensureSize() + target
        default: return -1
        }
        return offset
    }

    fileprivate func write(from buffer: UnsafePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        do {
            try fileHandle?.write(contentsOf: Data(bytes: buffer, count: Int(count)))
        } catch { return -28 }   // ENOSPC
        progressLock.withLock { bytesWritten += Int(count) }
        return count
    }

    private func ensureSize() -> Int64 {
        if size >= 0 { return size }
        if isLocalFile {
            size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            return max(size, 0)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, _ in
            box.total = Self.totalLength(from: response); semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let total = box.total { size = total }
        return max(size, 0)
    }

    private static func totalLength(from response: URLResponse?) -> Int64? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = range.split(separator: "/").last, let total = Int64(totalPart) {
            return total
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }
}

// C-convention trampolines — recover the transcoder from the opaque pointer.
private func sxRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegStreamTranscoder>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, size: size)
}
private func sxSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegStreamTranscoder>.fromOpaque(opaque).takeUnretainedValue().seek(to: offset, whence: whence)
}
private func sxWrite(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegStreamTranscoder>.fromOpaque(opaque).takeUnretainedValue().write(from: buffer, size: size)
}
private func sxInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let t = Unmanaged<FFmpegStreamTranscoder>.fromOpaque(opaque).takeUnretainedValue()
    return CFAbsoluteTimeGetCurrent() > t.deadline ? 1 : 0
}
private func sxGetHWFormat(_ ctx: UnsafeMutablePointer<AVCodecContext>?,
                           _ fmts: UnsafePointer<AVPixelFormat>?) -> AVPixelFormat {
    var p = fmts
    while let cur = p?.pointee, cur != AV_PIX_FMT_NONE {
        if cur == AV_PIX_FMT_VIDEOTOOLBOX { return cur }
        p = p?.advanced(by: 1)
    }
    return fmts?.pointee ?? AV_PIX_FMT_NONE
}
