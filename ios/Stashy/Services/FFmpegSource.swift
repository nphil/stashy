import Foundation
import Libavformat
import Libavcodec
import Libavutil

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
    private var deadline: CFAbsoluteTime = 0

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
                    lines.append("video: \(name) \(par.pointee.width)×\(par.pointee.height)")
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
