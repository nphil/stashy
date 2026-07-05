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

/// Phase 1b of on-device AI slow-motion. While engaged (playback ≤ 0.5×), a `CADisplayLink` pulls
/// consecutive decoded frames from the player's `AVPlayerItemVideoOutput` (the same tap the live blur
/// uses) and feeds each new pair to `SlowMoInterpolator`, synthesising the in-between frame(s).
///
/// **1b(A) — this stage** runs the pipeline and reports live telemetry (proof it works, visible in the
/// Stats overlay) WITHOUT changing what's on screen; the display swap that presents the synthesised frames
/// is 1b(B). The loop is **single-flight** (at most one interpolation outstanding) so it can never pile up
/// or stall real playback — if the NPU can't keep up it simply drops pairs.
@MainActor
final class SlowMoRunner {
    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let onTelemetry: (SlowMoTelemetry) -> Void
    private let interpolator: SlowMoInterpolator

    private var displayLink: CADisplayLink?
    private var previous: CVPixelBuffer?
    private var previousPTS: CMTime = .invalid
    private var inFlight = false
    private var telemetry = SlowMoTelemetry()

    init(width: Int, height: Int,
         outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         onTelemetry: @escaping (SlowMoTelemetry) -> Void) {
        self.interpolator = SlowMoInterpolator(width: width, height: height, interpolatedFrames: 1)
        self.outputProvider = outputProvider
        self.onTelemetry = onTelemetry
    }

    /// Start the VideoToolbox session (on the main actor, before any interpolation task exists) and, if
    /// supported, begin the display-link frame pull. If unsupported, reports `supported = false` and does
    /// nothing further (the caller keeps plain slow playback).
    func start() {
        telemetry.supported = interpolator.startIfNeeded()
        telemetry.active = telemetry.supported
        onTelemetry(telemetry)
        guard telemetry.supported else { return }

        let proxy = SlowMoLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(SlowMoLinkProxy.tick))
        proxy.link = link
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop the frame pull. Any in-flight interpolation is allowed to finish (single-flight, so nothing
    /// races the interpolator's state); the session is released when the runner deallocates.
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
        guard !inFlight else { onTelemetry(telemetry); return }
        inFlight = true
        onTelemetry(telemetry)

        let interp = interpolator
        Task.detached { [weak self, interp, pair] in
            let t0 = Date()
            let frames = await interp.interpolate(previous: pair.previous, previousPTS: pair.previousPTS,
                                                  current: pair.current, currentPTS: pair.currentPTS,
                                                  phases: [0.5])
            let ms = Date().timeIntervalSince(t0) * 1000
            let count = frames.count
            await MainActor.run {
                guard let self else { return }
                self.telemetry.synthesized += count
                self.telemetry.lastMs = ms
                self.inFlight = false
                self.onTelemetry(self.telemetry)
            }
        }
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
