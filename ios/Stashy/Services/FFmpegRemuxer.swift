import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Remuxes a remote media file (read on demand via URLSession range requests through a custom input
/// `AVIOContext`) into **fragmented MP4** — a pure container rewrite, no re-encode — capturing the
/// muxed bytes through a custom *output* `AVIOContext`. This is the foundation of the on-device
/// direct-play pipeline: most "exotic" files are just H.264/HEVC sitting in MKV/WebM and only need
/// their container swapped to something `AVPlayer` accepts.
///
/// Step 2 / first increment: a *verification probe*. It runs the full open → copy-streams →
/// write-header → mux-packets path and reports a one-line summary (streams copied, header bytes,
/// bytes produced, packets muxed), proving the write-side interop + muxing work on-device before the
/// `AVAssetResourceLoaderDelegate` that feeds these bytes to `AVPlayer` is built on top. To keep the
/// probe cheap it stops once `produceCap` bytes have been muxed (enough for the moov + first
/// fragments) rather than reading the whole remote file.
///
/// Fragmented MP4 (`movflags=frag_keyframe+empty_moov+default_base_moof`) is forward-only: the muxer
/// never seeks back to patch a moov, so a non-seekable custom output AVIO (nil seek) is sufficient and
/// the produced prefix is independently playable — exactly what progressive streaming to AVPlayer needs.
final class FFmpegRemuxer: @unchecked Sendable {
    private let url: URL
    private let session: URLSession

    // Input (read) state — same range-request approach proven in FFmpegSource.
    private var offset: Int64 = 0
    private var size: Int64 = -1
    private let ioBufferSize = 1 << 16          // 64 KB AVIO buffers (in + out)

    // Output (write) state.
    private var produced = Data()
    private let produceCap = 1 << 22            // stop the probe after ~4 MB muxed

    // Macros the Swift importer doesn't surface (identical to FFmpegSource).
    private let averrorEOF: Int32 = -541478725
    private let avseekSize: Int32 = 0x10000
    private let avseekForce: Int32 = 0x20000
    private let avfmtFlagCustomIO: Int32 = 0x0080

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

    /// Run the remux and return a short human-readable summary (or an error string). Raced against a
    /// timeout so a slow network / awkward demux never leaves the overlay stuck.
    func remuxSummary() async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await self.runRemuxDetached() }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return "remux timed out (slow IO / awkward demux)"
            }
            let result = await group.next() ?? "—"
            group.cancelAll()
            return result
        }
    }

    private func runRemuxDetached() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runRemux())
            }
        }
    }

    private func runRemux() -> String {
        // --- Input: open the source through a custom read/seek AVIO ---
        guard let inBuffer = av_malloc(ioBufferSize) else { return "in alloc failed" }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let readAVIO = avio_alloc_context(
            inBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 0, opaque,
            remuxRead, nil, remuxSeek
        ) else {
            av_free(inBuffer)
            return "in avio alloc failed"
        }

        var input = avformat_alloc_context()
        if let input {
            input.pointee.pb = readAVIO
            input.pointee.flags |= avfmtFlagCustomIO
        }
        let openResult = avformat_open_input(&input, nil, nil, nil)
        if openResult < 0 {
            freeAVIO(readAVIO)
            return "open failed (\(errString(openResult)))"
        }
        _ = avformat_find_stream_info(input, nil)

        // --- Output: an MP4 muxer writing into our in-memory buffer through a custom write AVIO ---
        var output: UnsafeMutablePointer<AVFormatContext>?
        let allocOut = avformat_alloc_output_context2(&output, nil, "mp4", nil)
        guard allocOut >= 0, let outputCtx = output else {
            cleanupInput(&input, readAVIO)
            return "out alloc failed (\(errString(allocOut)))"
        }

        guard let outBuffer = av_malloc(ioBufferSize) else {
            avformat_free_context(outputCtx)
            cleanupInput(&input, readAVIO)
            return "out alloc failed"
        }
        guard let writeAVIO = avio_alloc_context(
            outBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 1, opaque,
            nil, remuxWrite, nil   // write_flag=1, no seek (fragmented MP4 never seeks back)
        ) else {
            av_free(outBuffer)
            avformat_free_context(outputCtx)
            cleanupInput(&input, readAVIO)
            return "out avio alloc failed"
        }
        outputCtx.pointee.pb = writeAVIO

        // --- Copy audio/video streams 1:1 (drop subtitles/attachments MP4 can't hold) ---
        let nbStreams = Int(input!.pointee.nb_streams)
        var streamMapping = [Int](repeating: -1, count: nbStreams)
        var copied: [String] = []
        var outIndex = 0
        for i in 0..<nbStreams {
            guard let inStream = input!.pointee.streams[i], let inPar = inStream.pointee.codecpar else { continue }
            let type = inPar.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            guard let outStream = avformat_new_stream(outputCtx, nil) else { continue }
            if avcodec_parameters_copy(outStream.pointee.codecpar, inPar) < 0 { continue }
            // Clear the source container's codec tag so the MP4 muxer assigns a valid one (avc1/hvc1/mp4a).
            // Without this, HEVC-in-MKV → MP4 typically fails with "tag not found".
            outStream.pointee.codecpar.pointee.codec_tag = 0
            streamMapping[i] = outIndex
            outIndex += 1
            let name = String(cString: avcodec_get_name(inPar.pointee.codec_id))
            copied.append(type == AVMEDIA_TYPE_VIDEO
                ? "\(name) \(inPar.pointee.width)×\(inPar.pointee.height)"
                : "\(name) \(inPar.pointee.ch_layout.nb_channels)ch")
        }

        if outIndex == 0 {
            cleanupOutput(outputCtx, writeAVIO)
            cleanupInput(&input, readAVIO)
            return "no MP4-muxable streams"
        }

        // --- Write header with fragmented-MP4 flags ---
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0)
        let headerResult = avformat_write_header(outputCtx, &options)
        av_dict_free(&options)
        if headerResult < 0 {
            cleanupOutput(outputCtx, writeAVIO)
            cleanupInput(&input, readAVIO)
            return "write_header failed (\(errString(headerResult)))\ncopied: \(copied.joined(separator: ", "))"
        }
        let headerBytes = produced.count

        // --- Mux packets until the cap or EOF ---
        var packetCount = 0
        var reachedEOF = false
        var writeError: Int32 = 0
        let pkt = av_packet_alloc()
        while produced.count < produceCap {
            let r = av_read_frame(input, pkt)
            if r < 0 { reachedEOF = true; break }
            let inIdx = Int(pkt!.pointee.stream_index)
            let outIdx = (inIdx < streamMapping.count) ? streamMapping[inIdx] : -1
            if outIdx < 0 { av_packet_unref(pkt); continue }
            let inStream = input!.pointee.streams[inIdx]!
            let outStream = outputCtx.pointee.streams[outIdx]!
            av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
            pkt!.pointee.stream_index = Int32(outIdx)
            pkt!.pointee.pos = -1
            let w = av_interleaved_write_frame(outputCtx, pkt)  // takes ownership + resets pkt
            if w < 0 { writeError = w; break }
            packetCount += 1
        }
        if reachedEOF { _ = av_write_trailer(outputCtx) }

        var pktVar: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&pktVar)
        cleanupOutput(outputCtx, writeAVIO)
        cleanupInput(&input, readAVIO)

        if writeError < 0 {
            return "write_frame failed (\(errString(writeError)))\ncopied: \(copied.joined(separator: ", "))"
        }
        let status = reachedEOF ? "EOF" : "capped"
        return """
        mp4 · \(copied.count) streams · \(status)
        copied: \(copied.joined(separator: ", "))
        header: \(headerBytes) B · produced: \(produced.count) B · packets: \(packetCount)
        """
    }

    // MARK: - Cleanup

    private func cleanupInput(_ input: inout UnsafeMutablePointer<AVFormatContext>?, _ avio: UnsafeMutablePointer<AVIOContext>) {
        avformat_close_input(&input)   // leaves our pb alone (CUSTOM_IO)
        freeAVIO(avio)
    }

    private func cleanupOutput(_ output: UnsafeMutablePointer<AVFormatContext>, _ avio: UnsafeMutablePointer<AVIOContext>) {
        avformat_free_context(output)  // does not free our custom pb
        freeAVIO(avio)
    }

    private func freeAVIO(_ avio: UnsafeMutablePointer<AVIOContext>) {
        let buffer = avio.pointee.buffer   // avio may have realloc'd the original buffer
        var ctx: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&ctx)
        if let buffer { av_free(buffer) }
    }

    // MARK: - AVIO callbacks (invoked synchronously on the remux's background thread)

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        let want = Int(count)
        var request = URLRequest(url: url)
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

    fileprivate func write(from buffer: UnsafePointer<UInt8>?, size count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        produced.append(buffer, count: Int(count))
        return count
    }

    private func ensureSize() -> Int64 {
        if size >= 0 { return size }
        var request = URLRequest(url: url)
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

// C-convention trampolines: recover the remuxer from the opaque pointer. read/seek serve the input
// AVIO; write serves the output AVIO. In FFmpeg 7+ the write callback's buffer is `const uint8_t *`
// (→ UnsafePointer), while read's is a fillable `uint8_t *` (→ UnsafeMutablePointer).
private func remuxRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegRemuxer>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, size: size)
}

private func remuxSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegRemuxer>.fromOpaque(opaque).takeUnretainedValue().seek(to: offset, whence: whence)
}

private func remuxWrite(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<FFmpegRemuxer>.fromOpaque(opaque).takeUnretainedValue().write(from: buffer, size: size)
}
