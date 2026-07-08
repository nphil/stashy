import UIKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Live telemetry the runner reports to `ScenePlayerModel` for the Stats overlay (proof the AI slow-mo
/// pipeline is running on real frames). All fields are value types → `Sendable`.
struct SlowMoTelemetry: Sendable {
    var supported = true      // false ⇒ VTFrameProcessor session couldn't start on this device
    var active = false        // currently engaged (playback ≤ 0.5×)
    var sourceFrames = 0      // distinct decoded source frames seen since engaging
    var synthesized = 0       // interpolated frames produced
    var lastMs = 0.0          // wall-clock of the most recent interpolation
    var sourceFormat = ""     // fourcc of the decoded buffer (e.g. "BGRA") — diagnostics
    var sourceWidth = 0       // actual decoded buffer width
    var sourceHeight = 0      // actual decoded buffer height
    var sourceColor = ""      // color primaries / transfer function of the decoded buffer — diagnostics
    var interpSize = ""       // resolution interpolation runs at ("native" or upscaled to dodge the 720p crash)
    var skipReason = ""       // why interpolation was skipped (e.g. "HDR"), empty if running
}

/// A snapshot pair of consecutive decoded frames handed off the main actor to the interpolator.
/// `@unchecked Sendable`: the pixel buffers are treated as immutable once pulled from the video output.
private struct SlowMoFramePair: @unchecked Sendable {
    let previous: CVPixelBuffer
    let previousPTS: CMTime
    let current: CVPixelBuffer
    let currentPTS: CMTime
}

/// The result of one interpolation, marshalled back to the main actor for display. `@unchecked Sendable`
/// for the same reason (immutable snapshot buffers).
private struct SlowMoFrameResult: @unchecked Sendable {
    let interpolated: [CVPixelBuffer]
    let current: CVPixelBuffer
    let previousPTS: CMTime
    let currentPTS: CMTime
}

/// Phase 1b of on-device AI slow-motion. While engaged (playback ≤ 0.5× on an item that can slow-play), a
/// `CADisplayLink` pulls consecutive decoded frames from the player's `AVPlayerItemVideoOutput`, feeds each
/// new pair to `SlowMoInterpolator`, and presents the **real + synthesised** frames on a `SlowMoRenderView`
/// (overlaying the hidden `AVPlayerLayer`) so the slowed motion actually looks smooth.
///
/// Pacing: each frame (real or synthesised) is enqueued keyed by its **item time**, and every display tick
/// presents the newest frame whose item time the **live playback clock** has reached (minus a small `latency`
/// lead so interpolation, which is causal — the mid frame is only known once *both* neighbours arrive — has
/// headroom). Driving pacing off the item clock (`AVPlayerItemVideoOutput.itemTime(forHostTime:)`) rather than
/// a wall-clock anchor set once at engage means it can't drift as AVPlayer's real rate wanders from nominal,
/// and it self-heals across pause/stall/seek (the timebase freezes on pause and jumps on seek — we just
/// follow it). Single-flight (one interpolation outstanding) so it can never pile up or stall real playback.
@MainActor
final class SlowMoRunner {
    /// The view that shows the interpolated stream (overlaid on the player surface while engaged).
    let renderView = SlowMoRenderView(frame: .zero)

    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let rateProvider: () -> Double
    private let onTelemetry: (SlowMoTelemetry) -> Void

    /// Display latency (seconds) — must exceed the interpolation time so causal mid frames aren't late.
    private static let latency = 0.15

    private var interpolator: SlowMoInterpolator?
    private var configWidth = 0
    private var configHeight = 0
    private var displayLink: CADisplayLink?
    private var previous: CVPixelBuffer?
    private var previousPTS: CMTime = .invalid
    private var inFlight = false
    private var telemetry = SlowMoTelemetry()

    // Display FIFO: synthesised + real frames waiting to be shown, keyed by their ITEM time (seconds) and
    // ordered by it. Pacing is driven off the live playback clock in presentDue — there's no wall-clock
    // anchor to drift, and it self-heals across pause / stall / seek.
    private var displayQueue: [(buffer: CVPixelBuffer, itemTime: Double)] = []
    /// Bumped on every seek/discontinuity so an interpolation that was in flight across the seek is dropped
    /// (its frames belong to the old position) instead of being enqueued at a stale item time.
    private var epoch = 0

    init(outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         rateProvider: @escaping () -> Double,
         onTelemetry: @escaping (SlowMoTelemetry) -> Void) {
        self.outputProvider = outputProvider
        self.rateProvider = rateProvider
        self.onTelemetry = onTelemetry
    }

    /// Begin the display-link frame pull. The VideoToolbox session is created lazily from the first decoded
    /// frame's real dimensions (so it always matches the source).
    func start() {
        telemetry.active = true
        onTelemetry(telemetry)
        let proxy = SlowMoLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(SlowMoLinkProxy.tick))
        proxy.link = link
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop the frame pull and end the VideoToolbox session cleanly. `invalidate()` tears the session down
    /// on the shared VT queue (single-flight upstream means nothing is mid-process); ending it here — rather
    /// than letting the interpolator dealloc on the main actor — keeps `endSession` on the VT thread, which
    /// is what prevents the crash when leaving slow-mo (e.g. switching back to normal speed).
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        interpolator?.invalidate()
        interpolator = nil
        previous = nil
        previousPTS = .invalid
        displayQueue.removeAll()
        telemetry.active = false
        onTelemetry(telemetry)
    }

    fileprivate func step() {
        presentDue()   // pace the display FIFO every tick, independent of new-frame arrival

        guard let output = outputProvider() else { return }
        let now = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: now),
              let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) else { return }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return }

        // Interpolation factor scales with how slow we're playing so smoothness is constant: ~2× the source
        // frame rate at any rate (0.5× → 4× / 3 mids, 0.25× → 8× / 7 mids). Slower playback = more wall-time
        // budget per source pair, so the extra frames stay within the NPU's headroom. Changing the factor
        // needs a fresh session (the count is fixed at config time) — recreate when it changes, but only when
        // no interpolation is in flight (the detached task holds the current session). A rate change is a
        // deliberate, rare menu pick, so the one-frame re-seed hitch is unnoticeable.
        let mids = Self.desiredMids(forRate: rateProvider())
        if let interp = interpolator, interp.interpolatedFrames != mids, !inFlight {
            interp.invalidate()
            interpolator = nil
            previous = nil; previousPTS = .invalid
            displayQueue.removeAll()
        }

        // Lazily create the interpolator sized to the ACTUAL decoded buffer (never presentationSize — for
        // anamorphic content that display size differs from the coded buffer and would mismatch VideoToolbox).
        if interpolator == nil {
            telemetry.sourceWidth = width
            telemetry.sourceHeight = height
            telemetry.sourceFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))
            let attach = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
            let primaries = (attach[kCVImageBufferColorPrimariesKey as String] as? String) ?? "?"
            let transfer = (attach[kCVImageBufferTransferFunctionKey as String] as? String) ?? "?"
            telemetry.sourceColor = "\(primaries)/\(transfer)"
            let target = SlowMoInterpolator.safeInterpolationSize(width: width, height: height)
            telemetry.interpSize = (target.width != width || target.height != height)
                ? "\(target.width)×\(target.height)" : "native"
            // HDR / wide-gamut buffers (PQ 2084, HLG 2100, BT.2020 primaries) — detect via substring and skip.
            let isHDR = transfer.contains("2084") || transfer.uppercased().contains("HLG")
                     || transfer.contains("2100") || primaries.contains("2020")
            RemoteLog.shared.event("⚙︎ slowmo-start", [
                ("size", "\(width)×\(height)"),
                ("interp", telemetry.interpSize),
                ("fmt", telemetry.sourceFormat),
                ("prim", primaries), ("trc", transfer), ("hdr", "\(isHDR)")
            ])
            guard !isHDR else {
                telemetry.skipReason = "HDR/wide-gamut"
                telemetry.supported = false
                onTelemetry(telemetry)
                stop()
                return
            }
            // Create the interpolator but DON'T start the VideoToolbox session here on the main actor — the
            // session is context-affine, so it's started lazily inside interpolate() on the same background
            // task that calls process() (otherwise process throws -19730 "Processor is not initialized").
            let interp = SlowMoInterpolator(width: width, height: height, interpolatedFrames: mids)
            telemetry.supported = true
            onTelemetry(telemetry)
            interpolator = interp
            configWidth = width; configHeight = height
        }
        // A mid-stream size change (e.g. an engine rebuild on seek-reinit) would break the fixed-size
        // session — re-seed and skip rather than feed VideoToolbox a mismatched frame.
        guard width == configWidth, height == configHeight else {
            previous = nil; previousPTS = .invalid
            return
        }

        // Seed on the first frame, OR flush on a SEEK (item time jumps far forward or backward). Pauses and
        // stalls need NO special handling now that pacing follows the live item clock (see presentDue): the
        // timebase simply freezes, so nothing drifts and the frame on screen holds. A seek DOES need a flush —
        // the queued frames belong to the old position — plus a fresh anchor pair and an epoch bump so an
        // interpolation still in flight from before the seek is dropped rather than enqueued stale.
        let itemJump = previousPTS.isValid ? (now - previousPTS).seconds : 0
        if previous == nil || !previousPTS.isValid || itemJump < -0.05 || itemJump > 0.75 {
            epoch &+= 1
            displayQueue.removeAll()
            previous = buffer; previousPTS = now
            renderView.present(buffer)
            return
        }
        guard let prev = previous, now > previousPTS else { return }
        telemetry.sourceFrames += 1
        let pair = SlowMoFramePair(previous: prev, previousPTS: previousPTS, current: buffer, currentPTS: now)
        previous = buffer
        previousPTS = now

        // Single-flight: if the previous interpolation hasn't returned, drop this pair (never stall) — but
        // still show the real frame so playback doesn't freeze.
        guard !inFlight, let interp = interpolator else {
            enqueueDisplay(buffer, itemTime: now)
            onTelemetry(telemetry)
            return
        }
        inFlight = true
        onTelemetry(telemetry)
        let epoch = self.epoch   // tag this interpolation so a seek mid-flight discards its stale output

        Task.detached { [weak self, interp, pair, epoch] in
            let t0 = Date()
            let frames = await interp.interpolate(previous: pair.previous, previousPTS: pair.previousPTS,
                                                  current: pair.current, currentPTS: pair.currentPTS,
                                                  phases: interp.phases)
            let ms = Date().timeIntervalSince(t0) * 1000
            let result = SlowMoFrameResult(interpolated: frames, current: pair.current,
                                           previousPTS: pair.previousPTS, currentPTS: pair.currentPTS)
            await self?.onInterpolated(result, ms: ms, epoch: epoch)
        }
    }

    /// Fold a completed interpolation into telemetry + the display FIFO (main actor), free the single-flight
    /// slot, and enqueue the synthesised mid frame(s) followed by the real current frame in display order.
    private func onInterpolated(_ result: SlowMoFrameResult, ms: Double, epoch: Int) {
        inFlight = false
        // Discard an interpolation that finished after a seek — its frames are for the old position and would
        // enqueue at a stale item time (a wrong flash). The next fresh pair repopulates the FIFO.
        guard epoch == self.epoch else { return }
        telemetry.synthesized += result.interpolated.count
        telemetry.lastMs = ms
        onTelemetry(telemetry)

        let span = result.currentPTS - result.previousPTS
        let n = result.interpolated.count
        for (i, mid) in result.interpolated.enumerated() {
            let phase = Double(i + 1) / Double(n + 1)   // e.g. one frame → 0.5
            let midItem = result.previousPTS + CMTimeMultiplyByFloat64(span, multiplier: phase)
            enqueueDisplay(mid, itemTime: midItem)
        }
        enqueueDisplay(result.current, itemTime: result.currentPTS)
    }

    /// Insert a frame into the display FIFO keyed by its ITEM time (seconds), ordered by it.
    private func enqueueDisplay(_ buffer: CVPixelBuffer, itemTime: CMTime) {
        let t = itemTime.seconds
        guard t.isFinite else { return }
        let entry = (buffer: buffer, itemTime: t)
        if let idx = displayQueue.firstIndex(where: { $0.itemTime > t }) {
            displayQueue.insert(entry, at: idx)
        } else {
            displayQueue.append(entry)
        }
    }

    /// Present the newest queued frame whose ITEM time the live playback clock has reached, minus a small
    /// `latency` lead (in item time) so causal mid frames aren't already overdue. Because `cur` comes from
    /// the output's own timebase, pacing can't drift, and pause/stall/seek are handled for free: the timebase
    /// freezes on a pause (so the current frame simply holds) and jumps on a seek (handled by the flush in
    /// step()). Older due frames are dropped so it self-corrects if it ever falls behind.
    private func presentDue() {
        guard let output = outputProvider() else { return }
        let cur = output.itemTime(forHostTime: CACurrentMediaTime()).seconds
        guard cur.isFinite else { return }
        let due = cur - Self.latency * max(0.05, rateProvider())   // wall latency → item-time lead
        var toShow: CVPixelBuffer?
        while let first = displayQueue.first, first.itemTime <= due {
            toShow = first.buffer
            displayQueue.removeFirst()
        }
        if let toShow { renderView.present(toShow) }
        if displayQueue.count > 30 { displayQueue.removeFirst(displayQueue.count - 30) }   // safety bound
    }

    /// Mid frames to synthesise per source pair for a given playback rate — targets ~2× the source frame
    /// rate (silky) at any slow speed, capped at 7 (8×). 0.5× → 3, 0.33× → 5, 0.25× → 7. Slow-mo only
    /// engages ≤0.5×, so the input is always in that range.
    static func desiredMids(forRate rate: Double) -> Int {
        let mult = Int((2.0 / max(rate, 0.05)).rounded())   // 0.5→4, 0.25→8 (× factor)
        return min(7, max(1, mult - 1))
    }

    /// A CoreVideo pixel-format `OSType` as its 4-character code (e.g. `'BGRA'`), for diagnostics.
    private static func fourCC(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xff), UInt8((type >> 16) & 0xff),
                     UInt8((type >> 8) & 0xff), UInt8(type & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(type)"
    }
}

/// Weak-target proxy for the runner's `CADisplayLink` (the run loop retains the link, and the link retains
/// its target, so targeting the runner directly would leak it).
private final class SlowMoLinkProxy: NSObject {
    weak var target: SlowMoRunner?
    var link: CADisplayLink?
    init(target: SlowMoRunner) { self.target = target; super.init() }
    @objc func tick() {
        guard let target else { link?.invalidate(); link = nil; return }
        MainActor.assumeIsolated { target.step() }
    }
}
