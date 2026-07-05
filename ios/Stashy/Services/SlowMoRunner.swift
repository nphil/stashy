import UIKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Live telemetry the runner reports to `ScenePlayerModel` for the Stats overlay (proof the AI slow-mo
/// pipeline is actually running on real frames). All fields are value types → `Sendable`.
struct SlowMoTelemetry: Sendable {
    var supported = true      // false ⇒ VTFrameProcessor session couldn't start on this device
    var active = false        // currently engaged (playback ≤ 0.5×)
    var sourceFrames = 0      // distinct decoded source frames seen since engaging
    var synthesized = 0       // interpolated frames produced
    var lastMs = 0.0          // wall-clock of the most recent interpolation
}

/// A snapshot pair of consecutive decoded frames handed off the main actor to the interpolator.
/// `@unchecked Sendable`: the pixel buffers are treated as immutable once pulled from the video output
/// (we only read them), so carrying them into the background task is safe.
private struct SlowMoFramePair: @unchecked Sendable {
    let previous: CVPixelBuffer
    let previousPTS: CMTime
    let current: CVPixelBuffer
    let currentPTS: CMTime
}

/// Phase 1b of on-device AI slow-motion. While engaged (playback ≤ 0.5× on an item that can actually
/// slow-play), a `CADisplayLink` pulls consecutive decoded frames from the player's
/// `AVPlayerItemVideoOutput` (the same tap the live blur uses) and feeds each new pair to
/// `SlowMoInterpolator`, synthesising the in-between frame(s).
///
/// **1b(A) — this stage** runs the pipeline and reports live telemetry (proof it works, visible in the
/// Stats overlay) WITHOUT changing what's on screen; the display swap is 1b(B). The loop is **single-flight**
/// (at most one interpolation outstanding) so it can never pile up or stall real playback, and the
/// interpolator is sized from the **actual decoded buffer** (never `presentationSize`, which can differ for
/// anamorphic content and would mismatch VideoToolbox) so a size mismatch can't hard-fail.
@MainActor
final class SlowMoRunner {
    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let onTelemetry: (SlowMoTelemetry) -> Void

    private var interpolator: SlowMoInterpolator?
    private var configWidth = 0
    private var configHeight = 0
    private var displayLink: CADisplayLink?
    private var previous: CVPixelBuffer?
    private var previousPTS: CMTime = .invalid
    private var inFlight = false
    private var telemetry = SlowMoTelemetry()

    init(outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         onTelemetry: @escaping (SlowMoTelemetry) -> Void) {
        self.outputProvider = outputProvider
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

    /// Stop the frame pull. Any in-flight interpolation finishes (single-flight, so nothing races the
    /// interpolator's state); the session is released when the runner deallocates.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previous = nil
        previousPTS = .invalid
        telemetry.active = false
        onTelemetry(telemetry)
    }

    fileprivate func step() {
        guard let output = outputProvider() else { return }
        let now = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: now),
              let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) else { return }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return }

        // Lazily create the interpolator sized to the ACTUAL decoded buffer (never presentationSize — for
        // anamorphic content that display size differs from the coded buffer and would mismatch VideoToolbox).
        if interpolator == nil {
            let interp = SlowMoInterpolator(width: width, height: height, interpolatedFrames: 1)
            telemetry.supported = interp.startIfNeeded()
            onTelemetry(telemetry)
            guard telemetry.supported else { stop(); return }   // unsupported device → give up cleanly
            interpolator = interp
            configWidth = width; configHeight = height
        }
        // A mid-stream size change (e.g. an engine rebuild on seek-reinit) would break the fixed-size
        // session — re-seed and skip rather than feed VideoToolbox a mismatched frame.
        guard width == configWidth, height == configHeight else {
            previous = nil; previousPTS = .invalid
            return
        }

        // Seed on the first frame.
        guard let prev = previous, previousPTS.isValid else {
            previous = buffer; previousPTS = now
            return
        }
        // Only act when the source frame genuinely advanced (a new decoded frame, not a repeat).
        guard now > previousPTS else { return }
        telemetry.sourceFrames += 1
        let pair = SlowMoFramePair(previous: prev, previousPTS: previousPTS, current: buffer, currentPTS: now)
        previous = buffer
        previousPTS = now

        // Single-flight: if the previous interpolation hasn't returned, drop this pair (never stall).
        guard !inFlight, let interp = interpolator else { onTelemetry(telemetry); return }
        inFlight = true
        onTelemetry(telemetry)

        Task.detached { [weak self, interp, pair] in
            let t0 = Date()
            let frames = await interp.interpolate(previous: pair.previous, previousPTS: pair.previousPTS,
                                                  current: pair.current, currentPTS: pair.currentPTS,
                                                  phases: [0.5])
            let ms = Date().timeIntervalSince(t0) * 1000
            // Hop back to the main actor via a method call (avoids "sending self" into a MainActor.run
            // closure); Int/Double are Sendable, and the runner is @MainActor.
            await self?.recordInterpolation(synthesized: frames.count, ms: ms)
        }
    }

    /// Fold a completed interpolation's result into the telemetry (main actor) and free the single-flight slot.
    private func recordInterpolation(synthesized: Int, ms: Double) {
        telemetry.synthesized += synthesized
        telemetry.lastMs = ms
        inFlight = false
        onTelemetry(telemetry)
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
