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
/// Pacing: each frame (real or synthesised) is enqueued with a wall-clock **display time** derived from its
/// item time — `startWall + (itemTime − anchor)/rate + latency` — into a time-ordered FIFO; each display
/// tick presents the newest frame that's due. The small `latency` gives interpolation (which is causal —
/// the mid frame is only known once *both* neighbours arrive) headroom so mid frames aren't already late.
/// Single-flight (one interpolation outstanding) so it can never pile up or stall real playback.
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

    // Display FIFO: frames waiting to be shown, ordered by wall-clock display time.
    private var displayQueue: [(buffer: CVPixelBuffer, time: Double)] = []
    private var anchorItem: CMTime?     // item time of the first frame (display-time origin)
    private var startWall = 0.0         // wall clock (CACurrentMediaTime) at the first frame

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

    /// Stop the frame pull. Any in-flight interpolation finishes (single-flight, so nothing races the
    /// interpolator's state); the session is released when the runner deallocates.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
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
            let interp = SlowMoInterpolator(width: width, height: height, interpolatedFrames: 1)
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

        // Seed on the first frame OR re-anchor after a seek/discontinuity (item time jumps backward, or far
        // forward): clear the pipeline and present the new frame immediately, so the overlay follows the seek
        // instead of freezing on the last pre-seek frame. Otherwise it's black/frozen after any seek.
        let jump = previousPTS.isValid ? (now - previousPTS).seconds : 0
        if previous == nil || !previousPTS.isValid || jump < -0.05 || jump > 0.75 {
            displayQueue.removeAll()
            previous = buffer; previousPTS = now
            anchorItem = now
            startWall = CACurrentMediaTime()
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

        Task.detached { [weak self, interp, pair] in
            let t0 = Date()
            let frames = await interp.interpolate(previous: pair.previous, previousPTS: pair.previousPTS,
                                                  current: pair.current, currentPTS: pair.currentPTS,
                                                  phases: [0.5])
            let ms = Date().timeIntervalSince(t0) * 1000
            let result = SlowMoFrameResult(interpolated: frames, current: pair.current,
                                           previousPTS: pair.previousPTS, currentPTS: pair.currentPTS)
            await self?.onInterpolated(result, ms: ms)
        }
    }

    /// Fold a completed interpolation into telemetry + the display FIFO (main actor), free the single-flight
    /// slot, and enqueue the synthesised mid frame(s) followed by the real current frame in display order.
    private func onInterpolated(_ result: SlowMoFrameResult, ms: Double) {
        inFlight = false
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

    /// Insert a frame into the display FIFO at its wall-clock display time (time-ordered).
    private func enqueueDisplay(_ buffer: CVPixelBuffer, itemTime: CMTime) {
        guard let anchor = anchorItem else { return }
        let rate = max(0.05, rateProvider())
        let displayTime = startWall + (itemTime - anchor).seconds / rate + Self.latency
        let entry = (buffer: buffer, time: displayTime)
        if let idx = displayQueue.firstIndex(where: { $0.time > displayTime }) {
            displayQueue.insert(entry, at: idx)
        } else {
            displayQueue.append(entry)
        }
    }

    /// Present the newest frame whose display time has passed; drop older ones (self-correcting if behind).
    private func presentDue() {
        let now = CACurrentMediaTime()
        var toShow: CVPixelBuffer?
        while let first = displayQueue.first, first.time <= now {
            toShow = first.buffer
            displayQueue.removeFirst()
        }
        if let toShow { renderView.present(toShow) }
        if displayQueue.count > 30 { displayQueue.removeFirst(displayQueue.count - 30) }   // safety bound
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
