import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// First video stream's identity, used for routing (remux vs transcode).
struct FFmpegVideoInfo: Sendable {
    let codec: String
    let pixFmt: String
    let profile: String
    let width: Int
    let height: Int
}

/// Opens a remote media URL through libavformat using a custom `AVIOContext` that pulls bytes on demand
/// via URLSession range requests — our FFmpeg build enables only the `file`+`pipe` protocols, so remote
/// input has to be fed manually. Phase 1 / step 1: a read-only *probe* that reports the container and
/// per-stream codec/dimensions/duration, proving the demux interop works before the remux/transcode
/// pipeline is built on top. Runs off the main thread; the read callback blocks on a synchronous range
/// request, which is fine on a background queue.
final class FFmpegSource: @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private var offset: Int64 = 0
    private var size: Int64 = -1
    private let bufferSize = 1 << 16  // 64 KB AVIO buffer

    // AVERROR_EOF / AVSEEK_SIZE are macros the Swift importer doesn't surface, so define them directly.
    private let averrorEOF: Int32 = -541478725        // -MKTAG('E','O','F',' ')
    private let averrorExit: Int32 = -1414092869      // -MKTAG('E','X','I','T') — interrupt callback fired
    private let avseekSize: Int32 = 0x10000           // AVSEEK_SIZE
    private let avseekForce: Int32 = 0x20000          // AVSEEK_FORCE
    private let avfmtFlagCustomIO: Int32 = 0x0080     // AVFMT_FLAG_CUSTOM_IO

    /// Wall-clock deadline (CFAbsoluteTime) after which `interrupt()` aborts any in-flight FFmpeg IO.
    /// Set at the start of a probe; read by the @convention(c) interrupt callback FFmpeg polls between
    /// IO operations. This is what actually stops a pathological demux (e.g. AVI, whose end-of-file
    /// index needs hundreds of range-request round-trips) — a Task-group race can't, because the
    /// blocking C call isn't cancellable and the group would wait for it regardless.
    /// `fileprivate` so the top-level interrupt trampoline (not in the type's scope) can read it.
    fileprivate var deadline: CFAbsoluteTime = 0

    private final class Box: @unchecked Sendable {
        var data: Data?
        var total: Int64?
    }

    init(url: URL) {
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    deinit {
        // A custom URLSession retains itself + a delegate thread until invalidated — release it so probes
        // don't leak one each.
        session.invalidateAndCancel()
    }

    /// Open + read stream info, returning a short human-readable summary (or an error string). The
    /// interrupt callback (set in `runProbe`) bounds the work at `deadline`, so the detached probe is
    /// guaranteed to return; the outer race is just a backstop that surfaces a message if FFmpeg ever
    /// ignored the interrupt.
    func probeSummary() async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await self.runProbeDetached() }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return "probe timed out (slow IO / awkward demux)"
            }
            let result = await group.next() ?? "—"
            group.cancelAll()
            return result
        }
    }

    /// Quickly read the first video stream's codec + pixel format + profile, for routing decisions
    /// (remux vs transcode). Tries `open_input` alone first — for MP4/MKV the pixel format is already in
    /// the moov/CodecPrivate — and only falls back to `find_stream_info` if it isn't. Returns nil on
    /// failure/timeout (caller treats unknown as "attempt remux", i.e. no regression).
    func probeVideoInfo() async -> FFmpegVideoInfo? {
        await withTaskGroup(of: FFmpegVideoInfo?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: self.runVideoInfo())
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? nil
        }
    }

    private func runVideoInfo() -> FFmpegVideoInfo? {
        deadline = CFAbsoluteTimeGetCurrent() + 6
        guard let avioBuffer = av_malloc(bufferSize) else { return nil }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let avio = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0, opaque,
            ffmpegRead, nil, ffmpegSeek
        ) else {
            av_free(avioBuffer)
            return nil
        }
        var fmt = avformat_alloc_context()
        if let context = fmt {
            context.pointee.pb = avio
            context.pointee.flags |= avfmtFlagCustomIO
            context.pointee.interrupt_callback.callback = ffmpegInterrupt
            context.pointee.interrupt_callback.opaque = opaque
        }
        if avformat_open_input(&fmt, nil, nil, nil) < 0 {
            freeAVIO(avio)
            return nil
        }

        var info = firstVideoInfo(fmt)
        if info == nil || (info?.pixFmt.isEmpty ?? true) {
            _ = avformat_find_stream_info(fmt, nil)   // only pay for this if the moov didn't have it
            info = firstVideoInfo(fmt)
        }

        avformat_close_input(&fmt)
        freeAVIO(avio)
        return info
    }

    private func firstVideoInfo(_ fmt: UnsafeMutablePointer<AVFormatContext>?) -> FFmpegVideoInfo? {
        guard let f = fmt else { return nil }
        for i in 0..<Int(f.pointee.nb_streams) {
            guard let stream = f.pointee.streams[i], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            let codec = String(cString: avcodec_get_name(par.pointee.codec_id))
            var pix = ""
            if let n = av_get_pix_fmt_name(AVPixelFormat(rawValue: par.pointee.format)) { pix = String(cString: n) }
            var profile = ""
            if let p = avcodec_profile_name(par.pointee.codec_id, par.pointee.profile) { profile = String(cString: p) }
            return FFmpegVideoInfo(codec: codec, pixFmt: pix, profile: profile,
                                   width: Int(par.pointee.width), height: Int(par.pointee.height))
        }
        return nil
    }

    private func runProbeDetached() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runProbe())
            }
        }
    }

    private func runProbe() -> String {
        deadline = CFAbsoluteTimeGetCurrent() + 8   // abort the demux after 8s of wall-clock IO
        guard let avioBuffer = av_malloc(bufferSize) else { return "alloc failed" }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let avio = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0, opaque,
            ffmpegRead, nil, ffmpegSeek
        ) else {
            av_free(avioBuffer)
            return "avio alloc failed"
        }

        var fmt = avformat_alloc_context()
        if let context = fmt {
            context.pointee.pb = avio
            context.pointee.flags |= avfmtFlagCustomIO
            // FFmpeg polls this between IO ops; returning non-zero aborts open/find_stream_info/read.
            context.pointee.interrupt_callback.callback = ffmpegInterrupt
            context.pointee.interrupt_callback.opaque = opaque
        }

        let openResult = avformat_open_input(&fmt, nil, nil, nil)
        if openResult < 0 {
            freeAVIO(avio)                 // open_input won't free our pb (CUSTOM_IO); we own it
            return openResult == averrorExit
                ? "probe timed out (slow IO — container index needs many round-trips)"
                : "open failed (\(errString(openResult)))"
        }

        let infoResult = avformat_find_stream_info(fmt, nil)

        var lines: [String] = []
        if let f = fmt {
            var container = "?"
            if let iformat = f.pointee.iformat, let name = iformat.pointee.name {
                container = String(cString: name)
            }
            let durationSec = f.pointee.duration > 0 ? Double(f.pointee.duration) / 1_000_000 : 0
            lines.append("\(container) · \(Int(durationSec))s · \(f.pointee.nb_streams) streams")
            for i in 0..<Int(f.pointee.nb_streams) {
                guard let stream = f.pointee.streams[i], let par = stream.pointee.codecpar else { continue }
                let name = String(cString: avcodec_get_name(par.pointee.codec_id))
                let type = par.pointee.codec_type
                if type == AVMEDIA_TYPE_VIDEO {
                    // Show fourcc (hvc1/hev1/avc1), profile, and pixel format. Apple's HEVC decoder
                    // (Safari + iOS) only handles Main/Main 10 4:2:0; a 4:2:2/4:4:4 (Rext) pixel format
                    // here explains "plays in Chrome, fails on Apple" — a *decode* limit a remux can't
                    // fix, so those files need transcode, not remux.
                    var pixFmt = "?"
                    if let n = av_get_pix_fmt_name(AVPixelFormat(rawValue: par.pointee.format)) {
                        pixFmt = String(cString: n)
                    }
                    var profile = ""
                    if let p = avcodec_profile_name(par.pointee.codec_id, par.pointee.profile) {
                        profile = " " + String(cString: p)
                    }
                    lines.append("video: \(name) [\(Self.fourcc(par.pointee.codec_tag))]\(profile) \(pixFmt) \(par.pointee.width)×\(par.pointee.height)")
                } else if type == AVMEDIA_TYPE_AUDIO {
                    lines.append("audio: \(name) \(par.pointee.ch_layout.nb_channels)ch")
                } else if type == AVMEDIA_TYPE_SUBTITLE {
                    lines.append("subs: \(name)")
                }
            }
        }

        avformat_close_input(&fmt)         // frees fmt; leaves our pb alone (CUSTOM_IO)
        freeAVIO(avio)
        if infoResult == averrorExit { lines.append("(stream probe timed out — partial)") }
        return lines.isEmpty ? "no streams" : lines.joined(separator: "\n")
    }

    private func freeAVIO(_ avio: UnsafeMutablePointer<AVIOContext>) {
        let buffer = avio.pointee.buffer   // avio may have realloc'd the original buffer
        var ctx: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&ctx)
        if let buffer { av_free(buffer) }
    }

    // MARK: - AVIO callbacks (invoked synchronously on the probe's background thread)

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        let want = Int(count)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5   // so a single wedged read returns and lets FFmpeg poll the interrupt
        request.setValue("bytes=\(offset)-\(offset + Int64(want) - 1)", forHTTPHeaderField: "Range")

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            box.data = data
            box.total = Self.totalLength(from: response)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let total = box.total { size = total }
        guard let data = box.data, !data.isEmpty else { return averrorEOF }
        let n = min(data.count, want)
        data.copyBytes(to: buffer, count: n)
        offset += Int64(n)
        return Int32(n)
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

    private func ensureSize() -> Int64 {
        if size >= 0 { return size }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, _ in
            box.total = Self.totalLength(from: response)
            semaphore.signal()
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

    private func errString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, 128)
        return String(cString: buffer)
    }

    /// Render a codec_tag (little-endian fourcc) as a 4-char string, e.g. "hvc1"/"hev1"/"avc1".
    private static func fourcc(_ tag: UInt32) -> String {
        guard tag != 0 else { return "—" }
        let bytes = [tag, tag >> 8, tag >> 16, tag >> 24].map { UInt8($0 & 0xff) }
        let chars = bytes.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(chars)
    }
}

// C-convention trampolines: stateless, recovering the source from the opaque pointer.
private func ffmpegRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegSource>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, size: size)
}

private func ffmpegSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegSource>.fromOpaque(opaque).takeUnretainedValue().seek(to: offset, whence: whence)
}

// Polled by FFmpeg between IO operations; 1 aborts the in-flight open/find_stream_info/read.
private func ffmpegInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let source = Unmanaged<FFmpegSource>.fromOpaque(opaque).takeUnretainedValue()
    return CFAbsoluteTimeGetCurrent() > source.deadline ? 1 : 0
}
