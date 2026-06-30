import Foundation

/// Turns a *growing* fragmented-MP4 file (init = `ftyp`+`moov`, then one `moof`+`mdat` per keyframe) into
/// an **HLS byte-range media playlist**, so AVPlayer streams it the way it's actually built to — a
/// playlist of bounded byte-range segments that grows over time — instead of an open-ended progressive
/// download, which AVPlayer refuses to play (it re-requests from 0 forever, or errors out).
///
/// The remuxer writes `frag_keyframe` fragments, so every top-level `moof` begins at a video keyframe and
/// is therefore an independently-decodable HLS segment. A fragment is listed only once the *next* one has
/// appeared, so its byte length and duration are final and every advertised range is fully produced.
/// Parsing is cheap to re-run as the file grows: it walks only top-level box *headers* and dips into the
/// small `moov`/`moof` boxes (the big `mdat` payloads are skipped by size, never read here).
final class FMP4Index: @unchecked Sendable {
    private let fileURL: URL
    private let available: @Sendable () -> Int64
    private let isComplete: @Sendable () -> Bool
    /// Total media duration (from Stash metadata); used only for the final segment's EXTINF.
    private let totalDuration: Double

    private let lock = NSLock()
    private var scanOffset: Int64 = 0
    private var initLength: Int64 = -1          // end of `moov` = start of the first fragment
    private var haveMoov = false
    private var videoTrackID: UInt32 = 0
    private var timescale: UInt32 = 0
    /// One entry per parsed top-level `moof`: its file offset + the video track's baseMediaDecodeTime.
    private var fragOffsets: [Int64] = []
    private var fragTimes: [UInt64] = []

    init(fileURL: URL,
         available: @escaping @Sendable () -> Int64,
         isComplete: @escaping @Sendable () -> Bool,
         totalDuration: Double) {
        self.fileURL = fileURL
        self.available = available
        self.isComplete = isComplete
        self.totalDuration = totalDuration
    }

    /// Re-parse any newly-produced boxes, then build the current HLS media playlist. Returns nil until the
    /// init segment + at least one *complete* fragment exist (the server then keeps polling).
    func playlist(mediaName: String) -> String? {
        lock.withLock {
            scan()
            return buildPlaylist(mediaName: mediaName)
        }
    }

    func debugSummary() -> String {
        lock.withLock {
            "init=\(initLength)B · frags=\(fragOffsets.count) · ts=\(timescale) · vtrack=\(videoTrackID)"
        }
    }

    // MARK: - Scanning (top-level box walk)

    private func scan() {
        let avail = available()
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? fh.close() }

        func read(_ off: Int64, _ count: Int) -> Data? {
            guard off >= 0, count > 0, off + Int64(count) <= avail else { return nil }
            do { try fh.seek(toOffset: UInt64(off)); return try fh.read(upToCount: count) } catch { return nil }
        }

        while true {
            guard let header = read(scanOffset, 16) ?? read(scanOffset, 8), header.count >= 8 else { break }
            let size32 = be32(header, 0)
            let type = fourcc(header, 4)
            var size = Int64(size32)
            var headerLen: Int64 = 8
            if size32 == 1 {
                guard header.count >= 16 else { break }
                size = Int64(be64(header, 8)); headerLen = 16
            } else if size32 == 0 {
                break   // extends to EOF — can't bound a still-growing file
            }
            guard size >= headerLen else { break }
            let boxEnd = scanOffset + size

            switch type {
            case "moov":
                guard boxEnd <= avail, let box = read(scanOffset, Int(size)) else { return }
                parseMoov(box)
                initLength = boxEnd
                haveMoov = true
            case "moof":
                guard boxEnd <= avail, let box = read(scanOffset, Int(size)) else { return }
                let t = parseMoofVideoTime(box) ?? fragTimes.last ?? 0
                fragOffsets.append(scanOffset)
                fragTimes.append(t)
            default:
                // ftyp / mdat / free / styp / sidx — skip. Require the box end present so the *next* box
                // header read is valid (for a growing mdat this naturally waits until it's complete).
                guard boxEnd <= avail else { return }
            }
            scanOffset = boxEnd
        }
    }

    // MARK: - Box parsing (in-memory, small boxes only)

    /// Locate the video track's id + media timescale from a fully-read `moov` box.
    private func parseMoov(_ d: Data) {
        for trak in childBoxes(d, from: 8, to: d.count) where trak.type == "trak" {
            var trackID: UInt32 = 0
            var handler = ""
            var ts: UInt32 = 0
            for c in childBoxes(d, from: trak.start, to: trak.end) {
                switch c.type {
                case "tkhd":
                    let v = byte(d, c.start)
                    trackID = be32(d, c.start + (v == 1 ? 20 : 12))
                case "mdia":
                    for m in childBoxes(d, from: c.start, to: c.end) {
                        switch m.type {
                        case "hdlr": handler = fourcc(d, m.start + 8)
                        case "mdhd":
                            let v = byte(d, m.start)
                            ts = be32(d, m.start + (v == 1 ? 20 : 12))
                        default: break
                        }
                    }
                default: break
                }
            }
            if handler == "vide" { videoTrackID = trackID; timescale = ts; return }
        }
    }

    /// The video track's baseMediaDecodeTime (`tfdt`) within a fully-read `moof` box, if present.
    private func parseMoofVideoTime(_ d: Data) -> UInt64? {
        for traf in childBoxes(d, from: 8, to: d.count) where traf.type == "traf" {
            var tid: UInt32 = 0
            var bmdt: UInt64?
            for c in childBoxes(d, from: traf.start, to: traf.end) {
                switch c.type {
                case "tfhd": tid = be32(d, c.start + 4)               // after version/flags(4)
                case "tfdt":
                    let v = byte(d, c.start)
                    bmdt = v == 1 ? be64(d, c.start + 4) : UInt64(be32(d, c.start + 4))
                default: break
                }
            }
            if tid == videoTrackID, let bmdt { return bmdt }
        }
        return nil
    }

    /// Walk the child boxes contained in `d[from..<to]`, returning each child's type and *content* range
    /// (payload after its header). Robust to 64-bit (`size==1`) and to-EOF (`size==0`) sizes.
    private func childBoxes(_ d: Data, from: Int, to: Int) -> [(type: String, start: Int, end: Int)] {
        var out: [(type: String, start: Int, end: Int)] = []
        var off = from
        while off + 8 <= to {
            let size32 = be32(d, off)
            let type = fourcc(d, off + 4)
            var size = Int(size32)
            var headerLen = 8
            if size32 == 1 {
                guard off + 16 <= to else { break }
                size = Int(be64(d, off + 8)); headerLen = 16
            } else if size32 == 0 {
                size = to - off
            }
            guard size >= headerLen, off + size <= to else { break }
            out.append((type, off + headerLen, off + size))
            off += size
        }
        return out
    }

    // MARK: - Playlist

    private func buildPlaylist(mediaName: String) -> String? {
        guard haveMoov, initLength > 0, timescale > 0, !fragOffsets.isEmpty else { return nil }
        let complete = isComplete()
        let total = fragOffsets.count
        // A fragment is listable only once the next one exists (its byte length + duration are then
        // final); the last fragment is listable only when production is complete (its end = file end).
        let listable = complete ? total : total - 1
        guard listable >= 1 else { return nil }

        var segments: [(off: Int64, len: Int64, dur: Double)] = []
        var lastDur = 0.0
        for i in 0..<listable {
            let start = fragOffsets[i]
            let end = (i + 1 < total) ? fragOffsets[i + 1] : available()
            let len = end - start
            guard len > 0 else { continue }
            var dur: Double
            if i + 1 < total {
                dur = Double(fragTimes[i + 1] &- fragTimes[i]) / Double(timescale)
            } else {
                // Final segment: from its start time to the known total duration.
                dur = totalDuration - Double(fragTimes[i]) / Double(timescale)
            }
            if !(dur > 0) { dur = lastDur > 0 ? lastDur : 2.0 }
            lastDur = dur
            segments.append((start, len, dur))
        }
        guard !segments.isEmpty else { return nil }

        let target = max(1, Int(segments.map(\.dur).max()!.rounded(.up)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"\(mediaName)\",BYTERANGE=\"\(initLength)@0\"",
        ]
        for seg in segments {
            lines.append(String(format: "#EXTINF:%.3f,", seg.dur))
            lines.append("#EXT-X-BYTERANGE:\(seg.len)@\(seg.off)")
            lines.append(mediaName)
        }
        if complete { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Big-endian readers (0-based offsets into a freshly-read Data)
    //
    // All bounds-checked: this parses a *live-growing* file, so a malformed/edge box must degrade to a
    // benign zero/empty value rather than trap (a crash here would take the whole app down).

    private func byte(_ d: Data, _ i: Int) -> UInt8 {
        let b = d.startIndex + i
        return (i >= 0 && b < d.endIndex) ? d[b] : 0
    }

    private func be32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return 0 }
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }

    private func be64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4))
    }

    private func fourcc(_ d: Data, _ i: Int) -> String {
        let b = d.startIndex + i
        guard i >= 0, b + 4 <= d.endIndex else { return "" }
        return String(decoding: d[b..<b + 4], as: UTF8.self)
    }
}
