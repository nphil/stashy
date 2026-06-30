import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Produces an on-demand, **seekable** HLS stream from a remote mp4/mov source by remux (no re-encode).
///
/// Unlike the linear path (one growing file, forward-only), this reads the source's keyframe table from
/// the `moov` up front, lays out a keyframe-accurate segment grid, and emits each CMAF media segment
/// (moof+mdat) *on demand* by input-seeking a persistent demuxer to that keyframe. A shared init segment
/// (ftyp+moov) is produced once. Because the full grid + total duration are known immediately, AVPlayer
/// gets a VOD playlist it can seek anywhere in instantly — a far-forward scrub costs one segment remux
/// (~1–2 s), not "remux the whole gap up to here".
///
/// Keyframe discovery parses `stss`/`stts` from the source `moov` directly (FFmpeg's own index exposes the
/// keyframe flag only via a C bitfield Swift can't read). Sources without a sync-sample table (e.g. many
/// MKVs) are reported unsupported, and the caller uses the linear remux path instead.
final class HLSSegmentProducer: @unchecked Sendable {
    struct Segment { let start: Double; let duration: Double }

    private let url: URL
    private let session: URLSession

    // FFmpeg input AVIO read state + 4 MB read-ahead cache (one HTTP request per slab, not per 64 KB).
    private var offset: Int64 = 0
    private var size: Int64 = -1
    private var cache = Data()
    private var cacheStart: Int64 = -1
    private let readAhead = 1 << 22
    private let ioBufferSize = 1 << 18

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var inAVIO: UnsafeMutablePointer<AVIOContext>?
    private var videoIndex: Int32 = -1
    private var videoTimeBase = AVRational(num: 0, den: 1)

    private let lock = NSLock()   // serializes seeks/reads on the shared demuxer
    private var initData: Data?

    private(set) var segments: [Segment] = []
    private(set) var totalDuration: Double = 0
    private(set) var pixFmt: String = ""
    private(set) var videoCodec: String = ""
    /// Last few produced-segment results, for the Stats overlay.
    private var log: [String] = []

    // Macros the Swift importer doesn't surface.
    private let averrorEOF: Int32 = -541478725
    private let avfmtFlagCustomIO: Int32 = 0x0080
    private let avseekSize: Int32 = 0x10000
    private let avseekForce: Int32 = 0x20000
    private let avseekBackward: Int32 = 1            // AVSEEK_FLAG_BACKWARD
    private let avPktFlagKey: Int32 = 0x0001         // AV_PKT_FLAG_KEY
    private let avNoPTS: Int64 = Int64.min           // AV_NOPTS_VALUE

    private final class Box: @unchecked Sendable { var data: Data?; var total: Int64? }
    /// Output write target for one segment/init build.
    final class WriteSink: @unchecked Sendable { var data = Data() }

    init(url: URL) {
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - Preparation

    /// Open the source, read its keyframe grid, and lay out segments. Returns false when unsupported
    /// (not ISOBMFF / no sync-sample table) — the caller then uses the linear remux path.
    func prepare(targetSegment: Double = 6) -> Bool {
        lock.withLock { prepareLocked(targetSegment: targetSegment) }
    }

    private func prepareLocked(targetSegment: Double) -> Bool {
        // Parse the source moov's keyframe table first — if it has none, don't bother opening FFmpeg.
        guard let grid = buildKeyframeGrid(targetSegment: targetSegment) else {
            RemoteLog.shared.log("prod unsupported: no keyframe grid (→ linear remux)")
            return false
        }
        segments = grid.segments
        totalDuration = grid.duration

        // Open a persistent demuxer we'll seek repeatedly to produce segments.
        guard let inBuffer = av_malloc(ioBufferSize) else { return false }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let avio = avio_alloc_context(
            inBuffer.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 0, opaque,
            hlsRead, nil, hlsSeek
        ) else { av_free(inBuffer); return false }
        inAVIO = avio

        var ctx = avformat_alloc_context()
        if let c = ctx { c.pointee.pb = avio; c.pointee.flags |= avfmtFlagCustomIO }
        if avformat_open_input(&ctx, nil, nil, nil) < 0 { freeInputAVIO(); return false }
        input = ctx
        _ = avformat_find_stream_info(ctx, nil)

        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i], let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            videoIndex = Int32(i)
            videoTimeBase = st.pointee.time_base
            videoCodec = String(cString: avcodec_get_name(par.pointee.codec_id))
            if let pf = av_get_pix_fmt_name(AVPixelFormat(rawValue: par.pointee.format)) {
                pixFmt = String(cString: pf)
            }
            break
        }
        guard videoIndex >= 0 else { teardownLocked(); return false }
        RemoteLog.shared.log("prod ready: \(segments.count) segs · \(Int(totalDuration))s · \(videoCodec) \(pixFmt)")
        return true
    }

    // MARK: - Segment production (serialized on the shared demuxer)

    func initSegment() -> Data? {
        lock.withLock {
            if let initData { return initData }
            let d = build(start: nil, end: nil, headerOnly: true)
            initData = d
            return d
        }
    }

    func segment(_ index: Int) -> Data? {
        lock.withLock {
            guard index >= 0, index < segments.count else { return nil }
            let seg = segments[index]
            let end = (index + 1 < segments.count) ? segments[index + 1].start : max(totalDuration, seg.start + seg.duration)
            let t0 = CFAbsoluteTimeGetCurrent()
            let d = build(start: seg.start, end: end, headerOnly: false)
            note("seg \(index) @\(Int(seg.start))s → \(d?.count ?? 0)B in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
            return d
        }
    }

    /// Build the init segment (ftyp+moov, `headerOnly`) or a media segment (moof+mdat for `[start,end)`).
    private func build(start: Double?, end: Double?, headerOnly: Bool) -> Data? {
        guard let input else { return nil }

        if let start {
            let target = ticks(start, videoTimeBase)
            av_seek_frame(input, videoIndex, target, avseekBackward)
        }

        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0, let out = output else { return nil }
        let sink = WriteSink()
        let sinkOpaque = Unmanaged.passUnretained(sink).toOpaque()
        guard let outBuf = av_malloc(ioBufferSize) else { avformat_free_context(out); return nil }
        guard let wAVIO = avio_alloc_context(
            outBuf.assumingMemoryBound(to: UInt8.self), Int32(ioBufferSize), 1, sinkOpaque,
            nil, hlsWrite, nil
        ) else { av_free(outBuf); avformat_free_context(out); return nil }
        out.pointee.pb = wAVIO

        var mapping = [Int32](repeating: -1, count: Int(input.pointee.nb_streams))
        var outVideoIdx: Int32 = -1
        var oi: Int32 = 0
        for i in 0..<Int(input.pointee.nb_streams) {
            guard let ist = input.pointee.streams[i], let ipar = ist.pointee.codecpar else { continue }
            let t = ipar.pointee.codec_type
            guard t == AVMEDIA_TYPE_VIDEO || t == AVMEDIA_TYPE_AUDIO else { continue }
            guard let ost = avformat_new_stream(out, nil) else { continue }
            if avcodec_parameters_copy(ost.pointee.codecpar, ipar) < 0 { continue }
            ost.pointee.codecpar.pointee.codec_tag = 0       // → mp4 muxer assigns hvc1/avc1/mp4a
            ost.pointee.time_base = ist.pointee.time_base
            mapping[i] = oi
            if t == AVMEDIA_TYPE_VIDEO { outVideoIdx = oi }
            oi += 1
        }
        guard oi > 0 else { cleanupOutput(out, wAVIO); return nil }

        var opts: OpaquePointer?
        av_dict_set(&opts, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0)
        let hr = avformat_write_header(out, &opts)
        av_dict_free(&opts)
        guard hr >= 0 else { cleanupOutput(out, wAVIO); return nil }

        if headerOnly {
            let data = sink.data                 // ftyp + moov
            cleanupOutput(out, wAVIO)
            return data
        }

        let endTime = end ?? .greatestFiniteMagnitude
        let pkt = av_packet_alloc()
        var wroteAny = false
        while av_read_frame(input, pkt) >= 0 {
            let inIdx = Int(pkt!.pointee.stream_index)
            let outIdx = (inIdx < mapping.count) ? mapping[inIdx] : -1
            if outIdx < 0 { av_packet_unref(pkt); continue }
            let ist = input.pointee.streams[inIdx]!
            let ts = pkt!.pointee.pts != avNoPTS ? pkt!.pointee.pts : pkt!.pointee.dts
            let tsec = Double(ts) * q2d(ist.pointee.time_base)
            let isVideo = outIdx == outVideoIdx
            let isKey = (pkt!.pointee.flags & avPktFlagKey) != 0
            // Stop at the next segment's start keyframe (don't write it — it belongs to the next segment).
            if isVideo, isKey, wroteAny, tsec >= endTime - 0.001 { av_packet_unref(pkt); break }
            let ost = out.pointee.streams[Int(outIdx)]!
            av_packet_rescale_ts(pkt, ist.pointee.time_base, ost.pointee.time_base)
            pkt!.pointee.stream_index = outIdx
            pkt!.pointee.pos = -1
            if av_interleaved_write_frame(out, pkt) < 0 { break }
            wroteAny = true
            if tsec >= endTime + 2 { break }     // safety against an audio-only runaway tail
        }
        _ = av_write_trailer(out)
        var pktVar: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&pktVar)
        let data = sink.data
        cleanupOutput(out, wAVIO)
        return stripToFirstMoof(data)            // drop the per-run ftyp+moov; init segment is shared
    }

    // MARK: - Diagnostics

    func diagnostics() -> [String] {
        lock.withLock {
            ["hls \(videoCodec) \(pixFmt) · \(segments.count) segs · \(Int(totalDuration))s"] + log
        }
    }

    private func note(_ line: String) {
        RemoteLog.shared.log("prod \(line)")
        log.append(line)
        if log.count > 8 { log.removeFirst(log.count - 8) }
    }

    // MARK: - Teardown

    func teardown() { lock.withLock { teardownLocked() } }

    private func teardownLocked() {
        if input != nil { avformat_close_input(&input) }
        freeInputAVIO()
    }

    private func freeInputAVIO() {
        guard let avio = inAVIO else { return }
        let buffer = avio.pointee.buffer
        var ctx: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&ctx)
        if let buffer { av_free(buffer) }
        inAVIO = nil
    }

    private func cleanupOutput(_ output: UnsafeMutablePointer<AVFormatContext>, _ avio: UnsafeMutablePointer<AVIOContext>) {
        let buffer = avio.pointee.buffer
        var ctx: UnsafeMutablePointer<AVIOContext>? = avio
        avformat_free_context(output)
        avio_context_free(&ctx)
        if let buffer { av_free(buffer) }
    }

    // MARK: - Keyframe grid (parse source moov stss/stts)

    private func buildKeyframeGrid(targetSegment: Double) -> (segments: [Segment], duration: Double)? {
        guard let moov = fetchMoov() else { return nil }
        guard let (timescale, kfTimes, trackDuration) = parseMoovKeyframes(moov), kfTimes.count > 1 else { return nil }
        let duration = trackDuration > 0 ? trackDuration : (kfTimes.last ?? 0)
        guard duration > 0 else { return nil }
        _ = timescale

        var segs: [Segment] = []
        var segStart = kfTimes[0]
        for t in kfTimes.dropFirst() where t - segStart >= targetSegment {
            segs.append(Segment(start: segStart, duration: t - segStart))
            segStart = t
        }
        if duration > segStart { segs.append(Segment(start: segStart, duration: duration - segStart)) }
        return segs.isEmpty ? nil : (segs, duration)
    }

    /// Locate + fetch the `moov` box by walking top-level boxes (handles moov-at-end / non-faststart).
    private func fetchMoov() -> Data? {
        var pos: Int64 = 0
        for _ in 0..<8 {     // ftyp, (mdat), free, … — moov is within the first handful of top-level boxes
            guard let header = fetchRange(pos, 16), header.count >= 8 else { return nil }
            var boxSize = Int64(be32(header, 0))
            if boxSize == 1 { boxSize = Int64(be64(header, 8)) }   // 64-bit size
            else if boxSize == 0 { return nil }
            let type = fourcc(header, 4)
            if type == "moov" {
                guard boxSize > 8, boxSize < (64 << 20) else { return nil }   // sane cap (64 MB)
                return fetchRange(pos, Int(boxSize))
            }
            guard boxSize >= 8 else { return nil }
            pos += boxSize
        }
        return nil
    }

    /// Parse the video track's media timescale, keyframe decode-times (from `stss`+`stts`), and duration.
    private func parseMoovKeyframes(_ d: Data) -> (timescale: UInt32, kfTimes: [Double], duration: Double)? {
        for trak in children(d, 8, d.count) where trak.type == "trak" {
            var isVideo = false
            var timescale: UInt32 = 0
            var mediaDuration: UInt64 = 0
            var stts: [(count: UInt32, delta: UInt32)] = []
            var stss: [UInt32] = []
            for b in children(d, trak.start, trak.end) where b.type == "mdia" {
                for m in children(d, b.start, b.end) {
                    switch m.type {
                    case "hdlr": if fourcc(d, m.start + 8) == "vide" { isVideo = true }
                    case "mdhd":
                        let v = byte(d, m.start)
                        timescale = be32(d, m.start + (v == 1 ? 20 : 12))
                        mediaDuration = v == 1 ? be64(d, m.start + 24) : UInt64(be32(d, m.start + 16))
                    case "minf":
                        for n in children(d, m.start, m.end) where n.type == "stbl" {
                            for s in children(d, n.start, n.end) {
                                if s.type == "stts" { stts = parseStts(d, s.start, s.end) }
                                if s.type == "stss" { stss = parseStss(d, s.start, s.end) }
                            }
                        }
                    default: break
                    }
                }
            }
            guard isVideo, timescale > 0, !stts.isEmpty, !stss.isEmpty else { continue }
            let times = keyframeTimes(stts: stts, stss: stss, timescale: timescale)
            let duration = mediaDuration > 0 ? Double(mediaDuration) / Double(timescale) : (times.last ?? 0)
            return (timescale, times, duration)
        }
        return nil
    }

    private func parseStts(_ d: Data, _ start: Int, _ end: Int) -> [(count: UInt32, delta: UInt32)] {
        let count = Int(be32(d, start + 4))
        var out: [(UInt32, UInt32)] = []
        out.reserveCapacity(count)
        var off = start + 8
        for _ in 0..<count {
            guard off + 8 <= end else { break }
            out.append((be32(d, off), be32(d, off + 4)))
            off += 8
        }
        return out
    }

    private func parseStss(_ d: Data, _ start: Int, _ end: Int) -> [UInt32] {
        let count = Int(be32(d, start + 4))
        var out: [UInt32] = []
        out.reserveCapacity(count)
        var off = start + 8
        for _ in 0..<count {
            guard off + 4 <= end else { break }
            out.append(be32(d, off))
            off += 4
        }
        return out
    }

    /// Decode-time (seconds) of each sync sample, walking `stts` and `stss` in lockstep.
    private func keyframeTimes(stts: [(count: UInt32, delta: UInt32)], stss: [UInt32], timescale: UInt32) -> [Double] {
        var times: [Double] = []
        times.reserveCapacity(stss.count)
        var sttsIdx = 0
        var sampleInRun: UInt32 = 0
        var curSample: UInt32 = 1          // next sample number to account for (1-based)
        var cumTicks: Int64 = 0
        for s in stss {                    // ascending sample numbers
            while curSample < s, sttsIdx < stts.count {
                let entry = stts[sttsIdx]
                let remaining = entry.count - sampleInRun
                let need = s - curSample
                let step = min(remaining, need)
                cumTicks += Int64(step) * Int64(entry.delta)
                curSample += step
                sampleInRun += step
                if sampleInRun >= entry.count { sttsIdx += 1; sampleInRun = 0 }
            }
            times.append(Double(cumTicks) / Double(timescale))
        }
        return times
    }

    // MARK: - Box helpers (bounds-checked; operate on a fresh 0-based Data)

    private func children(_ d: Data, _ from: Int, _ to: Int) -> [(type: String, start: Int, end: Int)] {
        var out: [(type: String, start: Int, end: Int)] = []
        var off = from
        while off + 8 <= to {
            let size32 = be32(d, off)
            let type = fourcc(d, off + 4)
            var size = Int(size32)
            var headerLen = 8
            if size32 == 1 { guard off + 16 <= to else { break }; size = Int(be64(d, off + 8)); headerLen = 16 }
            else if size32 == 0 { size = to - off }
            guard size >= headerLen, off + size <= to else { break }
            out.append((type, off + headerLen, off + size))
            off += size
        }
        return out
    }

    private func byte(_ d: Data, _ i: Int) -> UInt8 {
        let b = d.startIndex + i
        return (i >= 0 && b < d.endIndex) ? d[b] : 0
    }
    private func be32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return 0 }
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }
    private func be64(_ d: Data, _ i: Int) -> UInt64 { UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4)) }
    private func fourcc(_ d: Data, _ i: Int) -> String {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return "" }
        return String(decoding: d[b..<b + 4], as: UTF8.self)
    }

    private func stripToFirstMoof(_ d: Data) -> Data {
        var off = 0
        while off + 8 <= d.count {
            let size32 = be32(d, off)
            var size = Int(size32)
            if size32 == 1 { if off + 16 > d.count { break }; size = Int(be64(d, off + 8)) }
            else if size32 == 0 { break }
            if fourcc(d, off + 4) == "moof" { return d.subdata(in: off..<d.count) }
            guard size >= 8 else { break }
            off += size
        }
        return d
    }

    // MARK: - Timebase + synchronous range fetch

    private func q2d(_ r: AVRational) -> Double { r.den != 0 ? Double(r.num) / Double(r.den) : 0 }
    private func ticks(_ seconds: Double, _ tb: AVRational) -> Int64 {
        tb.num > 0 ? Int64(seconds * Double(tb.den) / Double(tb.num)) : 0
    }

    /// One synchronous HTTP range read (used only for moov discovery, off the FFmpeg AVIO path).
    private func fetchRange(_ start: Int64, _ count: Int) -> Data? {
        guard count > 0 else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=\(start)-\(start + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, _, _ in box.data = data; sem.signal() }
        task.resume()
        sem.wait()
        return box.data
    }

    // MARK: - FFmpeg input AVIO (read-ahead) — invoked on the calling thread under `lock`

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
        var end = offset + Int64(max(want, readAhead)) - 1
        if size >= 0 { end = min(end, size - 1) }
        guard end >= offset else { return averrorEOF }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            box.data = data
            box.total = Self.totalLength(from: response)
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let total = box.total { size = total }
        guard let data = box.data, !data.isEmpty else { return averrorEOF }
        cache = data
        cacheStart = offset
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
        request.timeoutInterval = 8
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, _ in box.total = Self.totalLength(from: response); sem.signal() }
        task.resume()
        sem.wait()
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

// C-convention trampolines: recover the producer / write sink from the opaque pointer.
private func hlsRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return -1 }
    return Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, size: size)
}
private func hlsSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue().seek(to: offset, whence: whence)
}
private func hlsWrite(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return 0 }
    let sink = Unmanaged<HLSSegmentProducer.WriteSink>.fromOpaque(opaque).takeUnretainedValue()
    sink.data.append(buffer, count: Int(size))
    return size
}
