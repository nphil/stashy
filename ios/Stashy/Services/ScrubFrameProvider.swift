import UIKit
import AVFoundation
import VideoEngine

/// Where scrub previews are made from, for a scene whose Stash sprite sheet can't show them.
enum ScrubPreviewSource: Equatable, Sendable {
    /// A downloaded file AVFoundation opens itself: the exact frame at the thumb, from `AVAssetImageGenerator`.
    case exact(URL)
    /// Any other file, a downloaded MKV or the original file on the Stash server: the picture at the keyframe
    /// at or before the thumb, read through the engine's `FrameExtractor`.
    case keyframes(EngineSource)
}

/// Scrub previews made from the playing file while you drag the scrubber, shown in place of the Stash sprite
/// tile where there is none (a scene whose sprite sheet was never generated, or a downloaded file).
///
/// **Which source.** A sprite sheet wins wherever it exists: instant, no decoding, no server load. Stash
/// returns the sprite URLs for every scene whether or not the sheet exists, so a *stream* is only read once the
/// sheet's load has finished empty (`SpriteThumbnails.Status.missing`); a *downloaded* file costs no data, so it
/// isn't made to wait. A file AVFoundation opens keeps the exact frame (`.exact`); everything else gets the
/// keyframe picture from the engine (`.keyframes`). A server conversion (HLS) has no source: it shows the time.
///
/// **Cost control (keyframe pictures).** One slot every 10 s (`ScrubSlots`), the slot nearest the thumb: a 90
/// minute scene is at most 541 pictures, each made once and kept (`cacheLimit`). Only the newest wanted slot is
/// ever pending, a drag makes at most one picture per 80 ms (`ScrubPacer`), and the nearest picture on hand
/// shows meanwhile. Lifting the finger cancels the one in flight (the engine drops it at once and keeps the
/// video open for the next scrub). After three failures with nothing made, the preview gives up and the time
/// shows alone.
@Observable
@MainActor
final class ScrubFrameProvider {
    /// The picture for the thumb: nil before the first lands, between scrubs, and when there is no source. The
    /// caller shows the sprite tile, or just the time, then.
    private(set) var image: UIImage?

    @ObservationIgnored private var source: ScrubPreviewSource?
    /// Bumped whenever the source changes or the provider stops, so work begun before can tell it is stale.
    @ObservationIgnored private var generation = 0

    // `.exact`
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    /// Same job as `generation`, for the generator's completion handlers.
    @ObservationIgnored private var exactSerial = 0

    // `.keyframes`
    @ObservationIgnored private var reader: KeyframeReader?
    @ObservationIgnored private var cache: [Int: UIImage] = [:]
    /// Cached slots, oldest first, so the oldest is evicted at `cacheLimit`.
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private var missed: Set<Int> = []
    @ObservationIgnored private var wanted: Int?
    @ObservationIgnored private var duration: TimeInterval = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Which worker may clear `worker` on its way out: a cancelled one must not drop its successor.
    @ObservationIgnored private var workerSerial = 0
    @ObservationIgnored private var pacer = ScrubPacer()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var madeFirst = false
    /// The engine can't make pictures from this file: the preview shows the time alone.
    @ObservationIgnored private var unavailable = false

    /// 320 px pictures are about 230 KB decoded: 48 is about 11 MB.
    private static let cacheLimit = 48

    /// A tiny `@unchecked Sendable` box to carry the decoded `UIImage` from the generator's completion
    /// (an arbitrary queue) back to the main actor — the image is an immutable snapshot here.
    private final class Box: @unchecked Sendable { let image: UIImage; init(_ i: UIImage) { self.image = i } }

    // MARK: Lifecycle

    /// Point this at a scene's preview source, or nil for none (a server conversion plays). No-op for the
    /// source it already has. Nothing is opened or read until the first request.
    func configure(_ source: ScrubPreviewSource?) {
        guard source != self.source else { return }
        stop()
        self.source = source
    }

    /// Let go of everything held: the work in flight, the pictures, and the connection the engine reads
    /// through (cancelling it ends a read stuck in a dead network). The source stays, so a later request
    /// starts over from scratch.
    func stop() {
        generation += 1
        exactSerial += 1
        generator?.cancelAllCGImageGeneration()
        generator = nil
        worker?.cancel()
        worker = nil
        workerSerial += 1
        reader?.cancel()
        reader = nil
        cache = [:]
        recent = []
        missed = []
        wanted = nil
        failures = 0
        madeFirst = false
        unavailable = false
        pacer.reset()
        image = nil
    }

    /// The finger lifted: work still pending is dropped and the next scrub starts at once. What was already
    /// made stays cached; the picture goes so the next scrub doesn't flash the last one.
    func scrubEnded() {
        exactSerial += 1
        generator?.cancelAllCGImageGeneration()
        worker?.cancel()
        worker = nil
        workerSerial += 1
        wanted = nil
        pacer.reset()
        image = nil
    }

    // MARK: Requests

    /// The thumb is at `time` in a scene `duration` seconds long. `sprites` is where the Stash sprite sheet
    /// stands: it decides whether the stream's own pictures are needed.
    func request(_ time: TimeInterval, duration: TimeInterval, sprites: SpriteThumbnails.Status) {
        switch source {
        case .exact(let url)?:
            requestExact(time, url: url)
        case .keyframes(let file)?:
            guard mayMake(from: file, sprites: sprites) else { return }
            requestKeyframe(time, duration: duration, file: file)
        case nil:
            break
        }
    }

    /// A sprite sheet covers the scrub instantly, with no decoding and no server load. Without one, a stream is
    /// read only once Stash has said it has none, while a file on the phone costs nothing and needn't wait for the
    /// sheet's download attempt to fail (offline, that can take a while).
    private func mayMake(from file: EngineSource, sprites: SpriteThumbnails.Status) -> Bool {
        guard !unavailable, sprites != .ready else { return false }
        return file.url.isFileURL || sprites == .missing
    }

    // MARK: Exact frames (a local file AVFoundation opens)

    /// The exact frame at `time`. Each request cancels the one in flight, so a fast drag skips the positions in
    /// between and a frame lands once the finger slows enough for one decode to finish: exact when you settle.
    private func requestExact(_ time: TimeInterval, url: URL) {
        let generator = generator ?? Self.makeGenerator(for: url)
        self.generator = generator
        generator.cancelAllCGImageGeneration()
        exactSerial += 1
        let serial = exactSerial
        let cmt = CMTime(seconds: max(0, time), preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: cmt) { [weak self] cg, _, _ in
            guard let cg else { return }   // nil ⇒ cancelled (superseded) or failed — ignore
            let box = Box(UIImage(cgImage: cg))
            Task { @MainActor in
                // A frame that finished decoding as the finger lifted must not show at the next scrub.
                guard let self, serial == self.exactSerial else { return }
                self.image = box.image
            }
        }
    }

    private static func makeGenerator(for url: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true          // honour rotation metadata
        generator.requestedTimeToleranceBefore = .zero            // exact frame, not nearest keyframe
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 480, height: 480)   // preview-sized decode → cheap
        return generator
    }

    // MARK: Keyframe pictures (the engine's FrameExtractor)

    private func requestKeyframe(_ time: TimeInterval, duration: TimeInterval, file: EngineSource) {
        guard duration.isFinite, duration > 0 else { return }
        self.duration = duration
        let slot = ScrubSlots.slot(at: time, duration: duration)
        show(slot)
        guard slot != wanted else { return }
        wanted = slot
        guard worker == nil else { return }   // the running worker picks up the newest `wanted`
        workerSerial += 1
        let serial = workerSerial
        let generation = generation
        worker = Task { [weak self] in await self?.work(serial: serial, generation: generation, file: file) }
    }

    /// Makes the newest wanted slot, then the next newest that arrived meanwhile, until the thumb's slot is
    /// shown or has failed; each picture waits its turn in the pacer.
    private func work(serial: Int, generation: Int, file: EngineSource) async {
        defer { if serial == workerSerial { worker = nil } }
        while !Task.isCancelled, generation == self.generation, !unavailable {
            guard let first = wanted, cache[first] == nil, !missed.contains(first) else { return }
            let wait = pacer.delay(at: ContinuousClock.now)
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, generation == self.generation, let slot = wanted else { return }
            if cache[slot] == nil, !missed.contains(slot) { await make(slot, file: file, generation: generation) }
        }
    }

    private func make(_ slot: Int, file: EngineSource, generation: Int) async {
        guard let reader = openReader(for: file) else { return }
        let started = ContinuousClock.now
        let frame: ExtractedFrame
        do {
            frame = try await reader.extractor.frame(at: ScrubSlots.time(of: slot, duration: duration), maxWidth: ScrubSlots.width)
        } catch is CancellationError {
            return   // the finger lifted, or the player was stopped
        } catch {
            guard generation == self.generation else { return }
            missed.insert(slot)
            failures += 1
            // A file the engine can't read at all (no picture track, a source that can't seek): time alone.
            if failures >= 3, cache.isEmpty { unavailable = true }
            RemoteLog.shared.log("scrub preview: slot \(slot) failed (\(failures)\(unavailable ? ", giving up" : "")): \(error.localizedDescription)")
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        failures = 0
        store(UIImage(cgImage: frame.image), at: slot)
        if !madeFirst {
            madeFirst = true
            let took = (ContinuousClock.now - started).components
            let ms = Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15
            RemoteLog.shared.log("scrub preview: first picture, slot \(slot), \(Int(ms)) ms, \(frame.bytesRead) bytes read")
        }
        show(wanted ?? slot)
    }

    /// The reader for `file`, opened on first use. A source the engine has no reader for ends previews.
    private func openReader(for file: EngineSource) -> KeyframeReader? {
        if let reader { return reader }
        do {
            let made = try KeyframeReader(file)
            reader = made
            return made
        } catch {
            unavailable = true
            RemoteLog.shared.log("scrub preview: no reader (\(error.localizedDescription))")
            return nil
        }
    }

    private func store(_ picture: UIImage, at slot: Int) {
        if cache.updateValue(picture, forKey: slot) == nil { recent.append(slot) }
        if recent.count > Self.cacheLimit { cache[recent.removeFirst()] = nil }
    }

    /// The best picture on hand for `slot`: its own, else the nearest within four slots either side, else what
    /// already shows (so the preview doesn't blank while the thumb outruns the pictures).
    private func show(_ slot: Int) {
        var best = cache[slot]
        var distance = 1
        while best == nil, distance <= 4 {
            best = cache[slot - distance] ?? cache[slot + distance]
            distance += 1
        }
        if let best, best !== image { image = best }
    }
}

/// The engine's extractor with the source it reads through. Cancelling a source is permanent, so whoever makes
/// it owns it: this ends a read stuck in a dead network when the provider lets go, or the player is left.
private final class KeyframeReader: Sendable {
    let extractor: FrameExtractor
    private let source: any ByteRangeSource

    /// The extractor gets a source of its own for the same URL and headers as playback, never playback's
    /// (the engine's rule): separate sources share no connection or cache. Throws for a scheme it can't read
    /// or a file that won't open.
    init(_ file: EngineSource) throws {
        let source = try ByteRangeSources.make(for: file.url, headers: file.headers)
        self.source = source
        extractor = FrameExtractor(source: source, logger: .remoteLog)
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}

/// The slots keyframe pictures are made on: one every 10 s, numbered from the start of the scene.
private enum ScrubSlots {
    static let interval: TimeInterval = 10
    /// The widest a picture is, in pixels: a 160 pt preview on a 2× screen.
    static let width = 320
    /// The engine's own cap on a time; keeps the slot arithmetic far from overflow whatever the metadata says.
    private static let maxSeconds: TimeInterval = 10_000_000

    /// The slot nearest `time`, inside the scene.
    static func slot(at time: TimeInterval, duration: TimeInterval) -> Int {
        let length = min(duration, maxSeconds)
        guard time.isFinite, length > 0 else { return 0 }
        let last = Int((length / interval).rounded(.down))
        return min(last, max(0, Int((min(max(time, 0), length) / interval).rounded())))
    }

    /// Where a slot's picture is taken: inside the scene, and never at exactly 0 (a file whose first picture
    /// is stamped a moment after 0 has no keyframe at or before it, and the engine throws).
    static func time(of slot: Int, duration: TimeInterval) -> TimeInterval {
        min(max(TimeInterval(slot) * interval, 1), max(0, duration - 1))
    }
}

/// Paces the pictures made while a finger drags: the first of a scrub, or one after a pause, starts at once;
/// each next waits out `quiet` since the last began, so a drag makes a picture per pause, not one per touch.
private struct ScrubPacer {
    static let quiet: Duration = .milliseconds(80)

    private var lastStart: ContinuousClock.Instant?

    /// How long a picture asked for at `now` waits before it starts.
    mutating func delay(at now: ContinuousClock.Instant) -> Duration {
        var wait = Duration.zero
        if let lastStart, now - lastStart < Self.quiet { wait = Self.quiet - (now - lastStart) }
        lastStart = now.advanced(by: wait)
        return wait
    }

    /// A scrub ended: the next one starts at once.
    mutating func reset() { lastStart = nil }
}
