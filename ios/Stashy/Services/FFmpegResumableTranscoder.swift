import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// **Resumable** on-device re-encode (owner request: "resume the transcode from where I left off").
///
/// VideoToolbox is foreground-only and has no mid-stream checkpoint, so a long transcode that's
/// interrupted (app backgrounded or killed) otherwise restarts from scratch. This engine survives that by
/// splitting the work into independent, **keyframe-aligned video chunks**:
///
///  1. Scan the source's keyframes once and persist a fixed chunk **plan** (`plan.json`) to a per-item
///     work dir. The plan is authoritative and never recomputed differently across runs.
///  2. Encode each chunk (`chunk_NNNN.mp4`) as a standalone, video-only MP4 whose timestamps are rebased
///     to 0. A chunk is committed by an atomic rename from `.tmp` only after its trailer is written, so a
///     kill mid-chunk leaves a `.tmp` (or a moov-less file that won't open) that resume discards.
///  3. On resume, already-committed chunks are kept; encoding continues from the first missing chunk.
///  4. Finalize by remuxing the chunk videos in order (running-offset concat, stream copy — no re-encode)
///     interleaved with the source's audio copied in a single pass — so audio has **no per-chunk priming
///     seams** (the classic chunk-concat pitfall; sidestepped by never splitting/re-encoding the audio).
///
/// Chosen over single-file fragmented-MP4 append because a partial chunk is trivially detected (failed
/// open) and VideoToolbox parameter-set drift damages at most one seam instead of the whole file tail.
/// Self-contained: the existing `VideoTranscoder`/`FFmpegTranscoder` engines are untouched.
final class FFmpegResumableTranscoder: OnDeviceTranscoder, @unchecked Sendable {
    enum TranscodeError: LocalizedError {
        case unreadable, noVideo, encoderUnavailable(String), audioUnsupported(String), ffmpeg(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "FFmpeg couldn't open this file for transcoding."
            case .noVideo: return "No video track found."
            case .encoderUnavailable(let e): return "Hardware encoder \(e) is unavailable."
            case .audioUnsupported(let c): return "Audio codec \(c) can't be re-muxed to MP4 yet."
            case .ffmpeg(let m): return "Transcode failed: \(m)"
            }
        }
    }

    private let workDir: URL
    private let targetChunkSeconds: Double = 20   // media seconds per chunk (keyframe-rounded)

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }

    // Macros the Swift importer doesn't surface as constants (identical to FFmpegTranscoder).
    private let averrorEOF: Int32 = -541478725
    private let averrorEAGAIN: Int32 = -35
    private let avioFlagWrite: Int32 = 2
    private let avfmtGlobalHeader: Int32 = 0x0040
    private let codecFlagGlobalHeader: Int32 = 1 << 22
    private let swsBilinear: Int32 = 2
    private let seekBackward: Int32 = 1               // AVSEEK_FLAG_BACKWARD
    private let pktFlagKey: Int32 = 1                 // AV_PKT_FLAG_KEY
    private let avNoPTS: Int64 = Int64.min

    private static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]
    private static let hvc1Tag: UInt32 =
        UInt32(UInt8(ascii: "h")) | UInt32(UInt8(ascii: "v")) << 8
        | UInt32(UInt8(ascii: "c")) << 16 | UInt32(UInt8(ascii: "1")) << 24

    /// - Parameter workDir: a stable per-item directory (survives backgrounding/relaunch) that holds
    ///   `plan.json` and `chunk_NNNN.mp4`. Created if missing.
    init(workDir: URL) { self.workDir = workDir }

    // MARK: - Plan

    private struct Plan: Codable {
        let version: Int
        let settingsKey: String
        let tbNum: Int32
        let tbDen: Int32
        let chunks: [Bound]
        struct Bound: Codable { let start: Int64; let end: Int64 }   // pts in source video time base; end==Int64.max ⇒ EOF
    }

    private static func settingsKey(_ s: VideoTranscoder.Settings) -> String {
        "\(s.resolution.rawValue)-\(s.quality.rawValue)-\(s.codec.rawValue)"
    }
    private var planURL: URL { workDir.appendingPathComponent("plan.json") }
    private func chunkURL(_ i: Int) -> URL { workDir.appendingPathComponent(String(format: "chunk_%04d.mp4", i)) }

    // MARK: - Entry point

    func run(input: URL, output: URL, settings: VideoTranscoder.Settings,
             onProgress: @escaping @Sendable (Double) -> Void,
             onLog: @escaping @Sendable (String) -> Void,
             onStatus: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread { [self] in
                do { try runSync(inputPath: input.path, outputPath: output.path, settings: settings,
                                 onProgress: onProgress, onLog: onLog, onStatus: onStatus); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func runSync(inputPath: String, outputPath: String, settings: VideoTranscoder.Settings,
                         onProgress: @escaping @Sendable (Double) -> Void,
                         onLog: @escaping @Sendable (String) -> Void,
                         onStatus: @escaping @Sendable (String) -> Void) throws {
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let plan = try buildOrLoadPlan(inputPath: inputPath, settings: settings, onLog: onLog)
        let total = plan.chunks.count
        let committedAtStart = (0..<total).filter { FileManager.default.fileExists(atPath: chunkURL($0).path) }.count
        onLog("Resumable: \(total) chunks, \(committedAtStart) already done")
        RemoteLog.shared.event("⚙︎ resume-plan", [("chunks", total), ("done", committedAtStart)])

        for i in 0..<total {
            if isCancelled { throw CancellationError() }
            if FileManager.default.fileExists(atPath: chunkURL(i).path) {
                onProgress(Double(i + 1) / Double(total + 1))   // +1 reserves the last slice for finalize
                continue
            }
            try encodeChunk(inputPath: inputPath, index: i, plan: plan, settings: settings,
                            chunkBase: Double(i), chunkTotal: Double(total + 1),
                            onProgress: onProgress, onLog: onLog, onStatus: onStatus)
        }

        if isCancelled { throw CancellationError() }
        onStatus("Finalizing…")
        try finalize(inputPath: inputPath, outputPath: outputPath, plan: plan, settings: settings, onLog: onLog)
        onProgress(1)
        onStatus("")
    }

    // MARK: - Plan build (keyframe scan)

    private func buildOrLoadPlan(inputPath: String, settings: VideoTranscoder.Settings,
                                 onLog: @escaping @Sendable (String) -> Void) throws -> Plan {
        let key = Self.settingsKey(settings)
        if let data = try? Data(contentsOf: planURL),
           let existing = try? JSONDecoder().decode(Plan.self, from: data),
           existing.version == 1, existing.settingsKey == key, !existing.chunks.isEmpty {
            return existing   // resume the exact same plan
        }
        // A settings change (or first run) invalidates the prior plan + chunks. Keep any other files (the
        // caller's settings.json, used for relaunch-resume) — only drop the plan and chunk_*.mp4.
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: planURL)
        if let files = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("chunk_") { try? FileManager.default.removeItem(at: f) }
        }

        var inFmt = avformat_alloc_context()
        guard inFmt != nil else { throw TranscodeError.unreadable }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        inFmt!.pointee.interrupt_callback.callback = resumableInterrupt
        inFmt!.pointee.interrupt_callback.opaque = opaque
        guard avformat_open_input(&inFmt, inputPath, nil, nil) >= 0, let input = inFmt else {
            throw TranscodeError.unreadable
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&p) }
        guard avformat_find_stream_info(input, nil) >= 0 else { throw TranscodeError.unreadable }
        let vIdx = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vIdx >= 0, let vInStream = input.pointee.streams[Int(vIdx)] else { throw TranscodeError.noVideo }
        let tb = vInStream.pointee.time_base

        // Collect video keyframe PTS in a single demux-only pass (no decode → fast).
        var keyPts: [Int64] = []
        let pkt = av_packet_alloc()
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        while av_read_frame(input, pkt) >= 0 {
            if Int(pkt!.pointee.stream_index) == Int(vIdx), pkt!.pointee.flags & pktFlagKey != 0 {
                let pts = pkt!.pointee.pts != avNoPTS ? pkt!.pointee.pts : pkt!.pointee.dts
                if pts != avNoPTS { keyPts.append(pts) }
            }
            av_packet_unref(pkt)
            if isCancelled { throw CancellationError() }
        }
        keyPts.sort()

        // Group keyframes into ~targetChunkSeconds chunks; the last runs to EOF.
        var bounds: [Plan.Bound] = []
        if keyPts.count < 2 || tb.num <= 0 || tb.den <= 0 {
            bounds = [Plan.Bound(start: keyPts.first ?? 0, end: Int64.max)]   // not resumable, but valid
        } else {
            let span = Int64(targetChunkSeconds * Double(tb.den) / Double(tb.num))
            var chunkStart = keyPts[0]
            for k in keyPts.dropFirst() {
                if k - chunkStart >= span { bounds.append(Plan.Bound(start: chunkStart, end: k)); chunkStart = k }
            }
            bounds.append(Plan.Bound(start: chunkStart, end: Int64.max))
        }

        let plan = Plan(version: 1, settingsKey: key, tbNum: tb.num, tbDen: tb.den, chunks: bounds)
        let data = try JSONEncoder().encode(plan)
        try data.write(to: planURL, options: .atomic)   // fsynced before any chunk is encoded
        onLog("Planned \(bounds.count) chunks from \(keyPts.count) keyframes")
        return plan
    }

    // MARK: - Per-chunk encode (video only, rebased to 0)

    private func encodeChunk(inputPath: String, index: Int, plan: Plan, settings: VideoTranscoder.Settings,
                             chunkBase: Double, chunkTotal: Double,
                             onProgress: @escaping @Sendable (Double) -> Void,
                             onLog: @escaping @Sendable (String) -> Void,
                             onStatus: @escaping @Sendable (String) -> Void) throws {
        let bound = plan.chunks[index]
        let tmpURL = chunkURL(index).appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmpURL)

        var inFmt = avformat_alloc_context()
        guard inFmt != nil else { throw TranscodeError.unreadable }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        inFmt!.pointee.interrupt_callback.callback = resumableInterrupt
        inFmt!.pointee.interrupt_callback.opaque = opaque
        guard avformat_open_input(&inFmt, inputPath, nil, nil) >= 0, let input = inFmt else {
            throw TranscodeError.unreadable
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&p) }
        guard avformat_find_stream_info(input, nil) >= 0 else { throw TranscodeError.unreadable }

        var vDecCodec: UnsafePointer<AVCodec>?
        let vIdx = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, &vDecCodec, 0)
        guard vIdx >= 0, let vDecCodec, let vInStream = input.pointee.streams[Int(vIdx)],
              let vCodecpar = vInStream.pointee.codecpar else { throw TranscodeError.noVideo }
        let vtb = vInStream.pointee.time_base

        // Decoder: prefer VideoToolbox HW, fall back to multithreaded software.
        guard let vDecCtx = avcodec_alloc_context3(vDecCodec),
              avcodec_parameters_to_context(vDecCtx, vCodecpar) >= 0 else { throw TranscodeError.unreadable }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vDecCtx; avcodec_free_context(&p) }
        vDecCtx.pointee.thread_count = 0
        var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            vDecCtx.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
            vDecCtx.pointee.get_format = resumableGetHWFormat
        }
        defer { if hwDeviceCtx != nil { av_buffer_unref(&hwDeviceCtx) } }
        guard avcodec_open2(vDecCtx, vDecCodec, nil) >= 0 else { throw TranscodeError.unreadable }

        // Sizing / rate / bitrate — identical formula to FFmpegTranscoder so every chunk matches.
        let srcW = Int(vCodecpar.pointee.width), srcH = Int(vCodecpar.pointee.height)
        let outSize = VideoTranscoder.outputSize(naturalSize: CGSize(width: srcW, height: srcH),
                                                 maxDimension: settings.resolution.maxDimension)
        var fr = vInStream.pointee.avg_frame_rate
        if fr.num <= 0 || fr.den <= 0 { fr = vInStream.pointee.r_frame_rate }
        if fr.num <= 0 || fr.den <= 0 { fr = AVRational(num: 30, den: 1) }
        let fps = av_q2d(fr) > 0 ? av_q2d(fr) : 30
        var bitrate = VideoTranscoder.videoBitrate(width: outSize.width, height: outSize.height,
                                                   fps: fps, quality: settings.quality, codec: settings.codec)
        let srcBitrate = vCodecpar.pointee.bit_rate
        let targetCodecId = settings.codec == .hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264
        if vCodecpar.pointee.codec_id == targetCodecId, srcBitrate > 100_000 { bitrate = min(bitrate, Int(srcBitrate)) }

        // Output MP4 (video only) via avio to the temp path.
        var outFmtOpt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outFmtOpt, nil, "mp4", tmpURL.path) >= 0,
              let outFmt = outFmtOpt else { throw TranscodeError.ffmpeg("out alloc failed") }
        defer {
            if outFmt.pointee.pb != nil { avio_closep(&outFmt.pointee.pb) }
            avformat_free_context(outFmt)
        }
        let encName = settings.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
        guard let encCodec = avcodec_find_encoder_by_name(encName),
              let vEncCtx = avcodec_alloc_context3(encCodec) else { throw TranscodeError.encoderUnavailable(encName) }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vEncCtx; avcodec_free_context(&p) }
        vEncCtx.pointee.width = Int32(outSize.width)
        vEncCtx.pointee.height = Int32(outSize.height)
        vEncCtx.pointee.pix_fmt = AV_PIX_FMT_NV12
        vEncCtx.pointee.time_base = av_inv_q(fr)
        vEncCtx.pointee.framerate = fr
        vEncCtx.pointee.bit_rate = Int64(bitrate)
        vEncCtx.pointee.gop_size = Int32(max(2, Int(fps * 2)))
        vEncCtx.pointee.sample_aspect_ratio = vDecCtx.pointee.sample_aspect_ratio
        if outFmt.pointee.oformat.pointee.flags & avfmtGlobalHeader != 0 {
            vEncCtx.pointee.flags |= codecFlagGlobalHeader
        }
        av_opt_set(vEncCtx.pointee.priv_data, "realtime", "true", 0)
        guard avcodec_open2(vEncCtx, encCodec, nil) >= 0 else { throw TranscodeError.encoderUnavailable(encName) }
        guard let vOutStream = avformat_new_stream(outFmt, nil),
              avcodec_parameters_from_context(vOutStream.pointee.codecpar, vEncCtx) >= 0 else {
            throw TranscodeError.ffmpeg("out stream failed")
        }
        if settings.codec == .hevc { vOutStream.pointee.codecpar.pointee.codec_tag = Self.hvc1Tag }
        vOutStream.pointee.time_base = vEncCtx.pointee.time_base
        guard avio_open(&outFmt.pointee.pb, tmpURL.path, avioFlagWrite) >= 0,
              avformat_write_header(outFmt, nil) >= 0 else { throw TranscodeError.ffmpeg("write_header failed") }

        // Seek to the chunk's keyframe start (bound.start IS a keyframe, so BACKWARD lands exactly on it).
        av_seek_frame(input, Int32(vIdx), bound.start, seekBackward)
        avcodec_flush_buffers(vDecCtx)

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
        let spanTicks = bound.end == Int64.max ? 0 : Double(bound.end - bound.start)
        var reachedEnd = false
        var lastStatus = Date.distantPast
        var noptsPts: Int64 = 0   // monotonic fallback when the source frame has no timestamp

        func drainEncoder(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
            guard avcodec_send_frame(vEncCtx, frame) >= 0 else { throw TranscodeError.ffmpeg("enc send") }
            while true {
                let r = avcodec_receive_packet(vEncCtx, encPkt)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { throw TranscodeError.ffmpeg("enc recv") }
                encPkt!.pointee.stream_index = vOutStream.pointee.index
                av_packet_rescale_ts(encPkt, vEncCtx.pointee.time_base, vOutStream.pointee.time_base)
                encPkt!.pointee.pos = -1
                if av_interleaved_write_frame(outFmt, encPkt) < 0 { throw TranscodeError.ffmpeg("chunk write") }
            }
        }

        func encodeDecoded() throws -> Bool {   // returns false once the chunk's end is reached
            while true {
                let r = avcodec_receive_frame(vDecCtx, decFrame)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { throw TranscodeError.ffmpeg("decode") }
                let best = decFrame!.pointee.best_effort_timestamp
                if best != avNoPTS, best < bound.start { av_frame_unref(decFrame); continue }   // pre-roll
                if best != avNoPTS, bound.end != Int64.max, best >= bound.end {
                    av_frame_unref(decFrame); reachedEnd = true; return false
                }
                let usingHW = decFrame!.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
                var transferred: UnsafeMutablePointer<AVFrame>?
                defer { if transferred != nil { av_frame_free(&transferred) } }
                let src: UnsafeMutablePointer<AVFrame>?
                if usingHW {
                    transferred = av_frame_alloc()
                    guard av_hwframe_transfer_data(transferred, decFrame, 0) >= 0 else { throw TranscodeError.ffmpeg("hw xfer") }
                    src = transferred
                } else { src = decFrame }
                let sW = Int(src!.pointee.width), sH = Int(src!.pointee.height)
                let srcFmt = AVPixelFormat(rawValue: src!.pointee.format)
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
                        guard sws != nil else { throw TranscodeError.ffmpeg("scaler") }
                    }
                    scaled = av_frame_alloc()
                    scaled!.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
                    scaled!.pointee.width = Int32(outSize.width)
                    scaled!.pointee.height = Int32(outSize.height)
                    guard av_frame_get_buffer(scaled, 0) >= 0, sws_scale_frame(sws, scaled, src) >= 0 else {
                        throw TranscodeError.ffmpeg("scale")
                    }
                    encodeFrame = scaled
                }
                // Rebase to chunk-local 0 so the chunk is an independent, valid MP4.
                if best != avNoPTS {
                    encodeFrame!.pointee.pts = av_rescale_q(best - bound.start, vtb, vEncCtx.pointee.time_base)
                    if spanTicks > 0 {
                        let f = min(1, max(0, Double(best - bound.start) / spanTicks))
                        onProgress((chunkBase + f) / chunkTotal)
                        let now = Date()
                        if now.timeIntervalSince(lastStatus) >= 0.5 {
                            lastStatus = now
                            onStatus(String(format: "▸ chunk %d · %d%%", index + 1, Int(f * 100)))
                        }
                    }
                } else {
                    encodeFrame!.pointee.pts = noptsPts; noptsPts += 1
                }
                try drainEncoder(encodeFrame)
                av_frame_unref(decFrame)
            }
            return true
        }

        readLoop: while !isCancelled {
            let r = av_read_frame(input, pkt)
            if r < 0 { break }
            if Int(pkt!.pointee.stream_index) == Int(vIdx) {
                guard avcodec_send_packet(vDecCtx, pkt) >= 0 else { av_packet_unref(pkt); continue }
                let keepGoing = try encodeDecoded()
                av_packet_unref(pkt)
                if !keepGoing { break readLoop }
            } else {
                av_packet_unref(pkt)
            }
        }
        if isCancelled { throw CancellationError() }
        if !reachedEnd, avcodec_send_packet(vDecCtx, nil) >= 0 {
            _ = try encodeDecoded()          // hit EOF (last chunk): drain the decoder tail into the encoder
        }
        try drainEncoder(nil)
        guard av_write_trailer(outFmt) >= 0 else { throw TranscodeError.ffmpeg("chunk trailer") }
        if outFmt.pointee.pb != nil { avio_closep(&outFmt.pointee.pb) }

        // Commit atomically: a present chunk_NNNN.mp4 is, by construction, complete.
        try FileManager.default.moveItem(at: tmpURL, to: chunkURL(index))
    }

    // MARK: - Finalize (concat chunk videos + copy source audio, single pass)

    private func finalize(inputPath: String, outputPath: String, plan: Plan,
                          settings: VideoTranscoder.Settings, onLog: @escaping @Sendable (String) -> Void) throws {
        // Source (for the audio copy).
        var srcFmt = avformat_alloc_context()
        guard srcFmt != nil, avformat_open_input(&srcFmt, inputPath, nil, nil) >= 0, let src = srcFmt else {
            throw TranscodeError.unreadable
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = src; avformat_close_input(&p) }
        _ = avformat_find_stream_info(src, nil)
        var aSrcStream: UnsafeMutablePointer<AVStream>?
        let aIdx = av_find_best_stream(src, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if aIdx >= 0, let s = src.pointee.streams[Int(aIdx)] {
            let name = String(cString: avcodec_get_name(s.pointee.codecpar.pointee.codec_id))
            if Self.copyableAudio.contains(name) { aSrcStream = s }   // else: video-only output
        }

        // First committed chunk supplies the video codec params for the output track.
        var chunk0Fmt = avformat_alloc_context()
        guard chunk0Fmt != nil, avformat_open_input(&chunk0Fmt, chunkURL(0).path, nil, nil) >= 0,
              let chunk0 = chunk0Fmt else { throw TranscodeError.ffmpeg("chunk 0 unreadable") }
        _ = avformat_find_stream_info(chunk0, nil)
        guard let cv0 = chunk0.pointee.streams[0], let cv0par = cv0.pointee.codecpar else {
            var p: UnsafeMutablePointer<AVFormatContext>? = chunk0; avformat_close_input(&p)
            throw TranscodeError.ffmpeg("chunk 0 no video")
        }

        var outFmtOpt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outFmtOpt, nil, "mp4", outputPath) >= 0, let outFmt = outFmtOpt else {
            var p: UnsafeMutablePointer<AVFormatContext>? = chunk0; avformat_close_input(&p)
            throw TranscodeError.ffmpeg("final out alloc")
        }
        defer {
            if outFmt.pointee.pb != nil { avio_closep(&outFmt.pointee.pb) }
            avformat_free_context(outFmt)
        }
        guard let vOut = avformat_new_stream(outFmt, nil),
              avcodec_parameters_copy(vOut.pointee.codecpar, cv0par) >= 0 else {
            var p: UnsafeMutablePointer<AVFormatContext>? = chunk0; avformat_close_input(&p)
            throw TranscodeError.ffmpeg("final video stream")
        }
        vOut.pointee.codecpar.pointee.codec_tag =
            cv0par.pointee.codec_id == AV_CODEC_ID_HEVC ? Self.hvc1Tag : 0
        let vOutTb = cv0.pointee.time_base
        vOut.pointee.time_base = vOutTb
        var p0: UnsafeMutablePointer<AVFormatContext>? = chunk0; avformat_close_input(&p0)   // reopened per-chunk below

        var aOut: UnsafeMutablePointer<AVStream>?
        if let aSrcStream {
            if let s = avformat_new_stream(outFmt, nil),
               avcodec_parameters_copy(s.pointee.codecpar, aSrcStream.pointee.codecpar) >= 0 {
                s.pointee.codecpar.pointee.codec_tag = 0
                aOut = s
            }
        }

        guard avio_open(&outFmt.pointee.pb, outputPath, avioFlagWrite) >= 0,
              avformat_write_header(outFmt, nil) >= 0 else { throw TranscodeError.ffmpeg("final write_header") }

        // Two source readers merged by DTS so `av_interleaved_write_frame` never has to buffer a whole
        // track: `vpkt` = the next video packet (across chunks, with a running offset so the zero-based
        // chunks join into one timeline); `apkt` = the next source-audio packet (copied straight through,
        // so audio is never split → no per-chunk priming seams).
        let vpkt = av_packet_alloc()
        let apkt = av_packet_alloc()
        defer {
            var a: UnsafeMutablePointer<AVPacket>? = vpkt; av_packet_free(&a)
            var b: UnsafeMutablePointer<AVPacket>? = apkt; av_packet_free(&b)
        }
        let audioTb = aSrcStream?.pointee.time_base ?? AVRational(num: 1, den: 1)
        let commonTb = AVRational(num: 1, den: 1_000_000)   // AV_TIME_BASE for cross-stream DTS comparison

        var chunkIdx = 0
        var cCtx: UnsafeMutablePointer<AVFormatContext>?
        var chunkBase: Int64 = 0        // this chunk's output-timebase offset (= end of previous chunks)
        var chunkFirstDts: Int64 = avNoPTS
        var videoEnd: Int64 = 0

        // Fill `vpkt` with the next video packet (advancing across chunks). Returns false when video is done.
        func nextVideo() -> Bool {
            while true {
                if isCancelled { return false }
                if cCtx == nil {
                    if chunkIdx >= plan.chunks.count { return false }
                    var f = avformat_alloc_context()
                    guard f != nil, avformat_open_input(&f, chunkURL(chunkIdx).path, nil, nil) >= 0 else { return false }
                    _ = avformat_find_stream_info(f, nil)
                    cCtx = f
                    chunkBase = videoEnd
                    chunkFirstDts = avNoPTS
                }
                guard let c = cCtx else { return false }
                if av_read_frame(c, vpkt) < 0 { avformat_close_input(&cCtx); chunkIdx += 1; continue }
                if Int(vpkt!.pointee.stream_index) != 0 { av_packet_unref(vpkt); continue }
                let ctb = c.pointee.streams[0]!.pointee.time_base
                let raw = vpkt!.pointee.dts != avNoPTS ? vpkt!.pointee.dts : vpkt!.pointee.pts
                if chunkFirstDts == avNoPTS { chunkFirstDts = raw }
                let baseDts = vpkt!.pointee.dts != avNoPTS ? vpkt!.pointee.dts : raw
                let basePts = vpkt!.pointee.pts != avNoPTS ? vpkt!.pointee.pts : raw
                let outDts = chunkBase + av_rescale_q(baseDts - chunkFirstDts, ctb, vOutTb)
                let outPts = chunkBase + av_rescale_q(basePts - chunkFirstDts, ctb, vOutTb)
                vpkt!.pointee.dts = outDts
                vpkt!.pointee.pts = outPts
                vpkt!.pointee.duration = av_rescale_q(vpkt!.pointee.duration, ctb, vOutTb)
                vpkt!.pointee.stream_index = vOut.pointee.index
                vpkt!.pointee.pos = -1
                videoEnd = max(videoEnd, outDts + max(vpkt!.pointee.duration, 1))
                return true
            }
        }

        // Fill `apkt` with the next source-audio packet (rescaled to the output track). False when done.
        func nextAudio() -> Bool {
            guard let aOut else { return false }
            while av_read_frame(src, apkt) >= 0 {
                if Int(apkt!.pointee.stream_index) != Int(aIdx) { av_packet_unref(apkt); continue }
                av_packet_rescale_ts(apkt, audioTb, aOut.pointee.time_base)
                apkt!.pointee.stream_index = aOut.pointee.index
                apkt!.pointee.pos = -1
                return true
            }
            return false
        }

        var vHas = nextVideo()
        var aHas = aOut != nil ? nextAudio() : false
        while vHas || aHas {
            if isCancelled { throw CancellationError() }
            let writeVideo: Bool
            if vHas, aHas, let aOut {
                let vT = av_rescale_q(vpkt!.pointee.dts, vOutTb, commonTb)
                let aT = av_rescale_q(apkt!.pointee.dts, aOut.pointee.time_base, commonTb)
                writeVideo = vT <= aT
            } else {
                writeVideo = vHas
            }
            if writeVideo {
                if av_interleaved_write_frame(outFmt, vpkt) < 0 { throw TranscodeError.ffmpeg("final video write") }
                vHas = nextVideo()
            } else {
                if av_interleaved_write_frame(outFmt, apkt) < 0 { throw TranscodeError.ffmpeg("final audio write") }
                aHas = nextAudio()
            }
        }
        if cCtx != nil { avformat_close_input(&cCtx) }

        guard av_write_trailer(outFmt) >= 0 else { throw TranscodeError.ffmpeg("final trailer") }
        onLog("Finalized \(plan.chunks.count) chunks → \(aOut != nil ? "video+audio" : "video-only") MP4")
    }
}

// C-convention trampolines (mirror FFmpegTranscoder's, kept separate to avoid cross-file symbol coupling).
private func resumableInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<FFmpegResumableTranscoder>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
}
private func resumableGetHWFormat(_ ctx: UnsafeMutablePointer<AVCodecContext>?,
                                  _ fmts: UnsafePointer<AVPixelFormat>?) -> AVPixelFormat {
    var p = fmts
    while let cur = p?.pointee, cur != AV_PIX_FMT_NONE {
        if cur == AV_PIX_FMT_VIDEOTOOLBOX { return cur }
        p = p?.advanced(by: 1)
    }
    return fmts?.pointee ?? AV_PIX_FMT_NONE
}
