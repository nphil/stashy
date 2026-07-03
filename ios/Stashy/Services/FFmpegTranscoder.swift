import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// Universal on-device re-encode via FFmpeg, for files Apple's `AVAssetReader` can't even open
/// (MKV/WebM/AVI, and anything with an exotic codec). It demuxes with libavformat, decodes the video
/// with FFmpeg's software/hardware decoders, scales/normalises to NV12 8-bit 4:2:0 with libswscale, and
/// re-encodes with the **VideoToolbox hardware encoder** (`h264_videotoolbox` / `hevc_videotoolbox`) into
/// a plain MP4 that any iPhone can direct-play. It complements `VideoTranscoder` (AVFoundation), which
/// stays the path for native MP4/MOV sources.
///
/// Audio: stream-**copied** when the source codec is one an iPhone can play in MP4 (AAC/AC3/EAC3/MP3/
/// ALAC) — no re-encode, no quality loss. A codec that can't be copied (Opus/Vorbis/FLAC/DTS) throws a
/// clear `.audioUnsupported` so the user sees exactly why (a follow-up will add an FFmpeg → AAC audio
/// re-encode for those).
///
/// Reads and writes local files directly through FFmpeg's `file` protocol (the only input protocol our
/// build enables besides `pipe`), so no custom AVIO is needed here — the source is always an on-disk
/// downloaded file.
final class FFmpegTranscoder: OnDeviceTranscoder, @unchecked Sendable {
    enum TranscodeError: LocalizedError {
        case unreadable, noVideo, decoderUnavailable(String), encoderUnavailable(String)
        case audioUnsupported(String), writeFailed, ffmpeg(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "FFmpeg couldn't open this file for transcoding."
            case .noVideo: return "No video track found."
            case .decoderUnavailable(let c): return "No decoder available for \(c)."
            case .encoderUnavailable(let e): return "Hardware encoder \(e) is unavailable."
            case .audioUnsupported(let c): return "Audio codec \(c) can't be re-muxed to MP4 yet — video-only transcode isn't offered, so this file is skipped."
            case .writeFailed: return "Couldn't write the transcoded video."
            case .ffmpeg(let m): return "Transcode failed: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }

    // Macros the Swift importer doesn't surface as constants.
    private let averrorEOF: Int32 = -541478725          // -MKTAG('E','O','F',' ')
    private let averrorEAGAIN: Int32 = -35              // AVERROR(EAGAIN) on Darwin (EAGAIN == 35)
    private let avioFlagWrite: Int32 = 2               // AVIO_FLAG_WRITE
    private let avfmtGlobalHeader: Int32 = 0x0040       // AVFMT_GLOBALHEADER
    private let codecFlagGlobalHeader: Int32 = 1 << 22  // AV_CODEC_FLAG_GLOBAL_HEADER
    private let swsBilinear: Int32 = 2                 // SWS_BILINEAR

    /// Audio codecs an iPhone can decode inside an MP4, so we copy them through untouched.
    private static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    /// Transcode `input` → `output` (a fresh MP4). `onProgress` (0…1) is called off the main actor.
    func run(input: URL, output: URL, settings: VideoTranscoder.Settings,
             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // A dedicated thread, not the cooperative pool: the demux/decode/encode loop is a long,
            // fully-blocking C call that would otherwise starve a shared executor thread.
            Thread.detachNewThread { [self] in
                do {
                    try runSync(inputPath: input.path, outputPath: output.path,
                                settings: settings, onProgress: onProgress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking pipeline (runs on its own thread)

    private func runSync(inputPath: String, outputPath: String, settings: VideoTranscoder.Settings,
                         onProgress: @escaping @Sendable (Double) -> Void) throws {
        // --- Open input (path-based; set the interrupt callback first so cancel aborts a slow demux) ---
        var inFmt = avformat_alloc_context()
        guard inFmt != nil else { throw TranscodeError.unreadable }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        inFmt!.pointee.interrupt_callback.callback = transcodeInterrupt
        inFmt!.pointee.interrupt_callback.opaque = opaque
        guard avformat_open_input(&inFmt, inputPath, nil, nil) >= 0, let input = inFmt else {
            throw TranscodeError.unreadable
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&p) }
        guard avformat_find_stream_info(input, nil) >= 0 else { throw TranscodeError.unreadable }

        // --- Locate the video stream + its decoder ---
        var vDecCodec: UnsafePointer<AVCodec>?
        let vIdx = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, &vDecCodec, 0)
        guard vIdx >= 0, let vDecCodec, let vInStream = input.pointee.streams[Int(vIdx)] else {
            throw TranscodeError.noVideo
        }
        let vDecCodecName = String(cString: avcodec_get_name(vInStream.pointee.codecpar.pointee.codec_id))
        guard let vDecCtx = avcodec_alloc_context3(vDecCodec) else {
            throw TranscodeError.decoderUnavailable(vDecCodecName)
        }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vDecCtx; avcodec_free_context(&p) }
        guard avcodec_parameters_to_context(vDecCtx, vInStream.pointee.codecpar) >= 0,
              avcodec_open2(vDecCtx, vDecCodec, nil) >= 0 else {
            throw TranscodeError.decoderUnavailable(vDecCodecName)
        }

        // --- Optional audio stream: decide copy vs. reject up front ---
        var aInStream: UnsafeMutablePointer<AVStream>?
        let aIdx = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if aIdx >= 0, let s = input.pointee.streams[Int(aIdx)] {
            let name = String(cString: avcodec_get_name(s.pointee.codecpar.pointee.codec_id))
            guard Self.copyableAudio.contains(name) else { throw TranscodeError.audioUnsupported(name) }
            aInStream = s
        }

        // --- Target size / bitrate (shared sizing with the AVFoundation path) ---
        let srcW = Int(vDecCtx.pointee.width), srcH = Int(vDecCtx.pointee.height)
        let outSize = VideoTranscoder.outputSize(
            naturalSize: CGSize(width: srcW, height: srcH),
            maxDimension: settings.resolution.maxDimension)
        // Frame rate for the encoder's time base (fall back to 30 when the container doesn't declare one).
        var fr = vInStream.pointee.avg_frame_rate
        if fr.num <= 0 || fr.den <= 0 { fr = vInStream.pointee.r_frame_rate }
        if fr.num <= 0 || fr.den <= 0 { fr = AVRational(num: 30, den: 1) }
        let fps = av_q2d(fr)
        let bitrate = VideoTranscoder.videoBitrate(width: outSize.width, height: outSize.height,
                                                   fps: fps > 0 ? fps : 30,
                                                   quality: settings.quality, codec: settings.codec)

        // --- Output MP4 + VideoToolbox encoder ---
        var outFmtOpt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outFmtOpt, nil, "mp4", outputPath) >= 0,
              let outFmt = outFmtOpt else { throw TranscodeError.writeFailed }
        defer {
            if outFmt.pointee.pb != nil { avio_closep(&outFmt.pointee.pb) }
            avformat_free_context(outFmt)
        }

        let encName = settings.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
        guard let encCodec = avcodec_find_encoder_by_name(encName) else {
            throw TranscodeError.encoderUnavailable(encName)
        }
        guard let vEncCtx = avcodec_alloc_context3(encCodec) else {
            throw TranscodeError.encoderUnavailable(encName)
        }
        defer { var p: UnsafeMutablePointer<AVCodecContext>? = vEncCtx; avcodec_free_context(&p) }
        vEncCtx.pointee.width = Int32(outSize.width)
        vEncCtx.pointee.height = Int32(outSize.height)
        vEncCtx.pointee.pix_fmt = AV_PIX_FMT_NV12
        vEncCtx.pointee.time_base = av_inv_q(fr)
        vEncCtx.pointee.framerate = fr
        vEncCtx.pointee.bit_rate = Int64(bitrate)
        vEncCtx.pointee.gop_size = Int32(max(2, (fps > 0 ? fps : 30) * 2))
        // Keep the source display aspect ratio (encoder scales to width×height).
        vEncCtx.pointee.sample_aspect_ratio = vDecCtx.pointee.sample_aspect_ratio
        if outFmt.pointee.oformat.pointee.flags & avfmtGlobalHeader != 0 {
            vEncCtx.pointee.flags |= codecFlagGlobalHeader
        }
        guard avcodec_open2(vEncCtx, encCodec, nil) >= 0 else {
            throw TranscodeError.encoderUnavailable(encName)
        }
        guard let vOutStream = avformat_new_stream(outFmt, nil),
              avcodec_parameters_from_context(vOutStream.pointee.codecpar, vEncCtx) >= 0 else {
            throw TranscodeError.writeFailed
        }
        vOutStream.pointee.time_base = vEncCtx.pointee.time_base

        // Audio: a straight copy stream (params carried over from the source).
        var aOutStream: UnsafeMutablePointer<AVStream>?
        if let aInStream {
            guard let s = avformat_new_stream(outFmt, nil),
                  avcodec_parameters_copy(s.pointee.codecpar, aInStream.pointee.codecpar) >= 0 else {
                throw TranscodeError.writeFailed
            }
            s.pointee.codecpar.pointee.codec_tag = 0   // let the MP4 muxer assign a valid tag
            aOutStream = s
        }

        // --- Open the file and write the header ---
        guard avio_open(&outFmt.pointee.pb, outputPath, avioFlagWrite) >= 0 else {
            throw TranscodeError.writeFailed
        }
        guard avformat_write_header(outFmt, nil) >= 0 else { throw TranscodeError.writeFailed }

        // --- Transcode loop ---
        let totalSeconds: Double = {
            if input.pointee.duration > 0 { return Double(input.pointee.duration) / 1_000_000 }
            let d = Double(vInStream.pointee.duration) * av_q2d(vInStream.pointee.time_base)
            return d > 0 ? d : 0.1
        }()

        var sws: UnsafeMutablePointer<SwsContext>?   // this FFmpeg build types SwsContext as a named struct
        defer { if sws != nil { sws_freeContext(sws) } }
        let pkt = av_packet_alloc()
        let decFrame = av_frame_alloc()
        defer {
            var pk: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&pk)
            var fr: UnsafeMutablePointer<AVFrame>? = decFrame; av_frame_free(&fr)
        }

        // Everything below runs on this one thread, so the throttle state is a plain local (the closure is
        // intentionally non-Sendable — it captures and mutates `lastReported`/`nextPts`).
        var lastReported = -1.0
        var nextPts: Int64 = 0
        let report: (Double) -> Void = { seconds in
            let p = totalSeconds > 0 ? min(1, max(0, seconds / totalSeconds)) : 0
            if p - lastReported >= 0.01 { lastReported = p; onProgress(p) }
        }

        // Encode one scaled frame (or nil to flush) and drain the encoder into the muxer.
        func drainEncoder(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
            guard avcodec_send_frame(vEncCtx, frame) >= 0 else { throw TranscodeError.ffmpeg("encoder send failed") }
            while true {
                let r = avcodec_receive_packet(vEncCtx, pkt)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { throw TranscodeError.ffmpeg("encoder receive failed (\(errString(r)))") }
                pkt!.pointee.stream_index = vOutStream.pointee.index
                av_packet_rescale_ts(pkt, vEncCtx.pointee.time_base, vOutStream.pointee.time_base)
                pkt!.pointee.pos = -1
                let w = av_interleaved_write_frame(outFmt, pkt)   // takes ownership + unrefs pkt
                if w < 0 { throw TranscodeError.ffmpeg("write failed (\(errString(w)))") }
            }
        }

        // Decode packets from the video stream, scale to NV12, feed the encoder.
        func decodeAndEncode(_ inputPkt: UnsafeMutablePointer<AVPacket>?) throws {
            guard avcodec_send_packet(vDecCtx, inputPkt) >= 0 else { return }   // tolerate a bad packet
            while true {
                let r = avcodec_receive_frame(vDecCtx, decFrame)
                if r == averrorEAGAIN || r == averrorEOF { break }
                guard r >= 0 else { throw TranscodeError.ffmpeg("decode failed (\(errString(r)))") }
                // Lazily build the scaler from the first real frame's format/size.
                if sws == nil {
                    sws = sws_getContext(decFrame!.pointee.width, decFrame!.pointee.height,
                                         vDecCtx.pointee.pix_fmt,
                                         Int32(outSize.width), Int32(outSize.height), AV_PIX_FMT_NV12,
                                         swsBilinear, nil, nil, nil)
                    guard sws != nil else { throw TranscodeError.ffmpeg("scaler init failed") }
                }
                let nv12 = av_frame_alloc()
                defer { var f: UnsafeMutablePointer<AVFrame>? = nv12; av_frame_free(&f) }
                nv12!.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
                nv12!.pointee.width = Int32(outSize.width)
                nv12!.pointee.height = Int32(outSize.height)
                guard av_frame_get_buffer(nv12, 0) >= 0,
                      sws_scale_frame(sws, nv12, decFrame) >= 0 else {
                    throw TranscodeError.ffmpeg("scale failed")
                }
                // Carry the source timestamp into the encoder's time base (keeps A/V in sync with the
                // copied audio); fall back to a monotonic counter when the source has no PTS.
                let best = decFrame!.pointee.best_effort_timestamp
                if best != Int64.min {
                    nv12!.pointee.pts = av_rescale_q(best, vInStream.pointee.time_base, vEncCtx.pointee.time_base)
                    let sec = Double(best) * av_q2d(vInStream.pointee.time_base)
                    report(sec)
                } else {
                    nv12!.pointee.pts = nextPts; nextPts += 1
                }
                av_frame_unref(decFrame)
                try drainEncoder(nv12)
            }
        }

        var writeError: Error?
        readLoop: while !isCancelled {
            let r = av_read_frame(input, pkt)
            if r < 0 { break }   // EOF or interrupt
            let sIdx = Int(pkt!.pointee.stream_index)
            do {
                if sIdx == Int(vIdx) {
                    try decodeAndEncode(pkt)
                } else if let aOutStream, sIdx == Int(aIdx) {
                    // Straight audio remux: rescale to the output stream's time base and write.
                    av_packet_rescale_ts(pkt, aInStream!.pointee.time_base, aOutStream.pointee.time_base)
                    pkt!.pointee.stream_index = aOutStream.pointee.index
                    pkt!.pointee.pos = -1
                    if av_interleaved_write_frame(outFmt, pkt) < 0 {
                        throw TranscodeError.ffmpeg("audio write failed")
                    }
                }
            } catch {
                writeError = error
                av_packet_unref(pkt)
                break readLoop
            }
            av_packet_unref(pkt)
        }

        if let writeError { throw writeError }
        if isCancelled { throw CancellationError() }

        // Flush the decoder, then the encoder.
        try decodeAndEncode(nil)   // send a null packet → drain remaining decoded frames
        try drainEncoder(nil)      // send a null frame → drain the encoder
        report(totalSeconds)

        guard av_write_trailer(outFmt) >= 0 else { throw TranscodeError.writeFailed }
    }

    private func errString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, 128)
        return String(cString: buffer)
    }
}

/// C-convention interrupt trampoline: FFmpeg polls this between blocking IO ops; return 1 to abort.
private func transcodeInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<FFmpegTranscoder>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
}
