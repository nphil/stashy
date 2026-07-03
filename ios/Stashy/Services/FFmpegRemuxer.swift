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
    /// When the source is a local `file://` URL we read it directly via a FileHandle instead of URLSession
    /// range requests (URLSession doesn't honour byte ranges on file URLs) — this is how a *downloaded*
    /// HEVC/MKV plays offline through the same remux path the server stream uses.
    private let isLocalFile: Bool
    private var localHandle: FileHandle?
    private let ioBufferSize = 1 << 18          // 256 KB AVIO buffers (in + out)

    // Read-ahead cache: FFmpeg reads the input in small (≤ ioBufferSize) chunks, but one HTTP range
    // request per chunk meant thousands of round-trips for a large file — far too slow to keep AVPlayer
    // fed (a 4K file produced only ~400 KB before the player gave up). Each cache miss pulls a big slab in
    // one request and serves the many sequential reads that follow from memory.
    private var cacheStart: Int64 = -1
    private var cache = Data()
    private let readAhead = 1 << 22             // 4 MB per upstream fetch

    // Output (write) state. When `fileURL` is set the muxed bytes stream progressively to that file
    // (for loopback playback); otherwise they accumulate in `produced` (the in-memory probe).
    // `produceCap` bounds how many bytes are written before stopping (use Int.max for a full remux).
    private let fileURL: URL?
    private let produceCap: Int
    private let outerTimeout: Double
    private var produced = Data()
    private var fileHandle: FileHandle?
    /// Bytes muxed so far (file or memory). Read after completion in this phase; made observable for the
    /// growing-file server in the next phase.
    private(set) var bytesWritten = 0

    // Macros the Swift importer doesn't surface (identical to FFmpegSource).
    private let averrorEOF: Int32 = -541478725
    private let averrorExit: Int32 = -1414092869   // -MKTAG('E','X','I','T') — interrupt callback fired
    private let avseekSize: Int32 = 0x10000
    private let avseekForce: Int32 = 0x20000
    private let avfmtFlagCustomIO: Int32 = 0x0080
    private let avNoPTS: Int64 = Int64.min          // AV_NOPTS_VALUE

    /// Wall-clock deadline after which the interrupt callback aborts in-flight FFmpeg IO, so a
    /// pathological demux (e.g. AVI's end-of-file index over per-read range requests) can't hang.
    /// `fileprivate` so the top-level interrupt trampoline (not in the type's scope) can read it.
    fileprivate var deadline: CFAbsoluteTime = 0

    // Thread-safe production progress for the loopback server, which reads these from its own thread.
    private let progressLock = NSLock()
    private var finishedFlag = false
    /// Bytes safely written to the output so far.
    var producedBytes: Int { progressLock.withLock { bytesWritten } }
    /// True once the remux has stopped (EOF, error, or abort) — the server then stops waiting for more.
    var isFinished: Bool { progressLock.withLock { finishedFlag } }
    /// Final-size estimate: the source byte size (output ≈ input for a no-re-encode remux).
    var sourceByteSize: Int64 { max(size, 0) }
    /// Abort an in-flight remux promptly (e.g. when playback stops) via the interrupt deadline + flag.
    func abort() {
        progressLock.withLock { abortedFlag = true }
        deadline = 1
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var total: Int64?
        var error: Error?
    }

    /// Seconds to input-seek to before remuxing (0 = from the start). Used for seek-by-reinit: a far
    /// seek restarts the remux near the target keyframe instead of waiting for forward-only production to
    /// reach it. Output timestamps are zero-based from the seek point, so the served stream begins at 0
    /// and the player layers the absolute offset back on top.
    private let startTime: Double

    /// Current local playback position (seconds, in this stream's zero-based timeline). When set, the
    /// remux *paces* itself: it produces up to `paceLeadSeconds` ahead of the playhead, then waits — so a
    /// partially-watched file only downloads/remuxes what's reached (+ the lead), not the whole thing.
    /// Pacing only engages for large sources (≥ `paceThresholdBytes`); small files produce fully (no
    /// scrub regression). nil = never pace (the verification probe).
    private let playhead: (@Sendable () -> Double)?
    private let paceLeadSeconds: Double = 75
    private let paceThresholdBytes: Int64 = 200 << 20   // only pace sources larger than ~200 MB

    /// Set by `abort()` so the pacing wait (and the mux loop) bail out promptly. Separate from `deadline`
    /// because the pacing loop keeps bumping `deadline` forward to avoid a spurious no-progress timeout.
    private var abortedFlag = false
    private var isAborted: Bool { progressLock.withLock { abortedFlag } }
    /// Media position (seconds) produced so far — for the "produced ahead of playhead" diagnostics line.
    private var producedMediaSeconds = 0.0
    var producedSeconds: Double { progressLock.withLock { producedMediaSeconds } }

    init(url: URL, fileURL: URL? = nil, cap: Int = 1 << 22, timeout: Double = 14, startTime: Double = 0,
         playhead: (@Sendable () -> Double)? = nil) {
        self.url = url
        self.fileURL = fileURL
        self.produceCap = cap
        self.outerTimeout = timeout
        self.startTime = startTime
        self.playhead = playhead
        self.isLocalFile = url.isFileURL
        self.localHandle = url.isFileURL ? try? FileHandle(forReadingFrom: url) : nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    deinit {
        // A custom URLSession retains itself (and a delegate thread) until invalidated — leaking one per
        // playback/probe and eventually exhausting resources. Release it explicitly.
        session.invalidateAndCancel()
        try? localHandle?.close()
    }

    /// Run the remux and return a short human-readable summary (or an error string). The interrupt
    /// callback (set in `runRemux`) bounds the work at `deadline`, guaranteeing the detached task
    /// returns; the outer race is just a backstop if FFmpeg ever ignored the interrupt.
    func remuxSummary() async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await self.runRemuxDetached() }
            group.addTask {
                try? await Task.sleep(for: .seconds(self.outerTimeout))
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
        defer { progressLock.withLock { finishedFlag = true } }   // registered first → runs last (after file close)
        deadline = CFAbsoluteTimeGetCurrent() + max(outerTimeout - 3, 3)   // abort in-flight IO before the outer race
        // Stream to the temp file when one was requested (progressive playback); else accumulate in memory.
        if let fileURL {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            if fileHandle == nil { return "temp file open failed" }
        }
        defer { try? fileHandle?.close() }
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
            input.pointee.interrupt_callback.callback = remuxInterrupt
            input.pointee.interrupt_callback.opaque = opaque
        }
        let openResult = avformat_open_input(&input, nil, nil, nil)
        if openResult < 0 {
            freeAVIO(readAVIO)
            return openResult == averrorExit
                ? "remux timed out (slow IO — container index needs many round-trips)"
                : "open failed (\(errString(openResult)))"
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
        var videoInputIndex = -1
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
            if type == AVMEDIA_TYPE_VIDEO, videoInputIndex < 0 { videoInputIndex = i }
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
        // frag_keyframe flushes a fragment at every video keyframe, so each top-level `moof` begins at a
        // keyframe and is an independently-decodable unit — exactly what an HLS byte-range segment must be
        // (`FMP4Index` turns these fragments into the playlist). We deliberately do *not* set frag_duration
        // here: cutting fragments mid-GOP by time would produce segments that don't start on a keyframe,
        // which AVPlayer can't decode as HLS segments. empty_moov writes the init segment (with hvc1
        // parameter sets) up front so AVPlayer's EXT-X-MAP fetch has everything it needs.
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0)
        let headerResult = avformat_write_header(outputCtx, &options)
        av_dict_free(&options)
        if headerResult < 0 {
            cleanupOutput(outputCtx, writeAVIO)
            cleanupInput(&input, readAVIO)
            return "write_header failed (\(errString(headerResult)))\ncopied: \(copied.joined(separator: ", "))"
        }
        let headerBytes = bytesWritten

        // --- Seek-by-reinit: jump the input to the requested start before muxing ---
        // av_seek_frame(BACKWARD) lands on the keyframe at/just-before startTime; packet timestamps are
        // then zero-based (shift subtracted below) so the served stream begins at 0.
        if startTime > 0, videoInputIndex >= 0, let vst = input!.pointee.streams[videoInputIndex] {
            let tb = vst.pointee.time_base
            let target = tb.num > 0 ? Int64(startTime * Double(tb.den) / Double(tb.num)) : 0
            av_seek_frame(input, Int32(videoInputIndex), target, 1 /* AVSEEK_FLAG_BACKWARD */)
        }

        // --- Mux packets until the cap or EOF ---
        var packetCount = 0
        var reachedEOF = false
        var interrupted = false
        var writeError: Int32 = 0
        var tsShiftSeconds = -1.0   // set from the first muxed packet; subtracted to zero-base output
        var lastVideoPts = 0.0      // produced media position (seconds, this stream's timeline) for pacing
        let pkt = av_packet_alloc()
        while bytesWritten < produceCap {
            if isAborted { interrupted = true; break }
            // Pace: once we're `paceLeadSeconds` ahead of the playhead on a large source, wait (don't
            // race to EOF). Keep bumping `deadline` so the no-progress interrupt doesn't fire while we're
            // intentionally idle. Resumes when the playhead advances (or stays idle while paused).
            if let playhead, size >= paceThresholdBytes {
                while !isAborted, lastVideoPts - playhead() > paceLeadSeconds {
                    deadline = CFAbsoluteTimeGetCurrent() + 20
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if isAborted { interrupted = true; break }
            }
            let r = av_read_frame(input, pkt)
            if r < 0 { reachedEOF = (r == averrorEOF); interrupted = (r == averrorExit); break }
            if playhead != nil { deadline = CFAbsoluteTimeGetCurrent() + 20 }   // progress → push the watchdog
            let inIdx = Int(pkt!.pointee.stream_index)
            let outIdx = (inIdx < streamMapping.count) ? streamMapping[inIdx] : -1
            if outIdx < 0 { av_packet_unref(pkt); continue }
            let inStream = input!.pointee.streams[inIdx]!
            let outStream = outputCtx.pointee.streams[outIdx]!
            // Zero-base timestamps from the seek point (only when we seeked).
            if startTime > 0 {
                let tb = inStream.pointee.time_base
                let q = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
                let raw = pkt!.pointee.dts != avNoPTS ? pkt!.pointee.dts : pkt!.pointee.pts
                if tsShiftSeconds < 0, raw != avNoPTS { tsShiftSeconds = Double(raw) * q }
                // Until a valid reference timestamp is seen, don't shift (a negative shift would push
                // timestamps forward instead of zero-basing them).
                let shift = (tsShiftSeconds >= 0 && q > 0) ? Int64(tsShiftSeconds / q) : 0
                if pkt!.pointee.pts != avNoPTS { pkt!.pointee.pts -= shift }
                if pkt!.pointee.dts != avNoPTS { pkt!.pointee.dts -= shift }
                // Drop any pre-roll packet that lands before the seek point (negative after shifting).
                if pkt!.pointee.dts != avNoPTS, pkt!.pointee.dts < 0 { av_packet_unref(pkt); continue }
            }
            // Track produced media position from the video stream (drives pacing + diagnostics).
            if inIdx == videoInputIndex, pkt!.pointee.pts != avNoPTS {
                let tb = inStream.pointee.time_base
                if tb.den > 0 { lastVideoPts = Double(pkt!.pointee.pts) * Double(tb.num) / Double(tb.den) }
                progressLock.withLock { producedMediaSeconds = lastVideoPts }
            }
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
        let status = interrupted ? "timed out (partial)" : reachedEOF ? "EOF" : "capped"
        return """
        mp4 · \(copied.count) streams · \(status)
        copied: \(copied.joined(separator: ", "))
        header: \(headerBytes) B · produced: \(bytesWritten) B · packets: \(packetCount)
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

        // Serve from the read-ahead cache when the offset falls inside it (the common sequential case).
        if cacheStart >= 0, offset >= cacheStart, offset < cacheStart + Int64(cache.count) {
            let from = Int(offset - cacheStart)
            let n = min(want, cache.count - from)
            cache.withUnsafeBytes { raw in
                buffer.update(from: raw.baseAddress!.advanced(by: from).assumingMemoryBound(to: UInt8.self), count: n)
            }
            offset += Int64(n)
            return Int32(n)
        }

        // Local file: read directly at the current offset (URLSession can't byte-range a file:// URL).
        if isLocalFile {
            guard let handle = localHandle else { return averrorEOF }
            do {
                try handle.seek(toOffset: UInt64(max(0, offset)))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { return averrorEOF }
                let n = min(data.count, want)
                data.copyBytes(to: buffer, count: n)
                offset += Int64(n)
                return Int32(n)
            } catch {
                return -5   // AVERROR(EIO)
            }
        }

        // Miss: pull a big slab starting at `offset` in one request; subsequent reads hit the cache.
        var end = offset + Int64(max(want, readAhead)) - 1
        if size >= 0 { end = min(end, size - 1) }
        guard end >= offset else { return averrorEOF }

        // Retry a failed slab a few times: a transient network stall on a long HEVC/MKV remux (a primary
        // daily route) must NOT be reported as EOF — that writes the trailer + ENDLIST and AVPlayer sees a
        // clean end mid-movie (fires onEnded, no `.failed`, watchdog already disarmed). We distinguish a
        // genuine end-of-file (a *successful* empty response — no transport error) from a failure (a
        // non-nil completion error, e.g. a timeout / connection-lost), retrying only the latter and finally
        // returning EIO so `reachedEOF` stays false and no trailer is written. Poll the abort flag between
        // attempts so teardown stays prompt. (Residual gap: a server that never sends Content-Range keeps
        // `size == -1`; we still rely on the error flag, which is correct as long as EOF arrives as a clean
        // empty response rather than a dropped connection.)
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if isAborted { return averrorExit }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8   // so a single wedged read returns and lets FFmpeg poll the interrupt
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: request) { data, response, err in
                box.data = data
                box.total = Self.totalLength(from: response)
                box.error = err
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if let total = box.total { size = total }
            if let data = box.data, !data.isEmpty {
                cache = data
                cacheStart = offset
                let n = min(data.count, want)
                data.copyBytes(to: buffer, count: n)
                offset += Int64(n)
                return Int32(n)
            }
            // Empty response with no transport error → genuine EOF. With an error → a stall/failure: back
            // off (polling abort so we bail promptly) and retry.
            if box.error == nil { return averrorEOF }
            if attempt < maxAttempts - 1 {
                for _ in 0..<10 { if isAborted { return averrorExit }; Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        return -5   // AVERROR(EIO): a persistent read failure, not EOF — no trailer, player can error/fallback
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
        if let fileHandle {
            do {
                try fileHandle.write(contentsOf: Data(bytes: buffer, count: Int(count)))
            } catch {
                return -28   // AVERROR(ENOSPC) — disk full; don't lie to FFmpeg that the bytes landed
            }
        } else {
            produced.append(buffer, count: Int(count))
        }
        // Only advance on success — a swallowed write error previously still counted the bytes as written.
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

// Polled by FFmpeg between IO operations; 1 aborts the in-flight open/find_stream_info/read.
private func remuxInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let remuxer = Unmanaged<FFmpegRemuxer>.fromOpaque(opaque).takeUnretainedValue()
    return CFAbsoluteTimeGetCurrent() > remuxer.deadline ? 1 : 0
}
