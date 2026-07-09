import UIKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// On-device AI video upscaling (Phase 1): while engaged, every decoded frame is run through
/// VideoToolbox's **low-latency super-resolution scaler** (`VTLowLatencySuperResolutionScaler`, iOS 26,
/// Neural-Engine accelerated, fixed 2×) and presented on a Metal overlay (`SlowMoRenderView` — reused;
/// it's a generic "present a pixel buffer" view whose Lanczos pass then covers any remaining scale to
/// screen). The overlay lives INSIDE the player's zoom container, so pinch-zoom transforms it identically
/// to the video — which is the whole point: zoomed-in playback stops looking soft.
///
/// Design notes (hard-won from the slow-mo -19730 saga — same VTFrameProcessor family, same landmines):
///  • The session is thread-affine: startSession/process/endSession all happen on ONE serial queue.
///  • Buffers must conform to the configuration's own source/destination pixel-buffer attributes
///    (biplanar 420v, IOSurface-backed) — the player's BGRA frames are CoreImage-converted first.
///  • The models have device-specific input caps iOS 26 can't query — engage only for ≤720p-class
///    sources (which is also exactly the "this video needs help" case).
///  • Stateless per frame: no pairing, no pacing FIFO — so seeks/pauses need NO special handling.
///  • Single-flight: if a frame arrives while one is processing, it's dropped (the overlay holds the
///    last upscaled frame); an anti-freeze fallback presents the raw frame if nothing has been shown
///    for a while, so a wedged session can never freeze playback.

/// Live telemetry for the Stats overlay. All value types → Sendable.
struct UpscaleTelemetry: Sendable {
    var supported = true      // false ⇒ the scaler couldn't start / rejected input on this device
    var active = false        // runner engaged
    var frames = 0            // frames successfully upscaled since engaging
    var lastMs = 0.0          // wall-clock of the most recent upscale
    var inSize = ""           // source frame size fed to the model
    var outSize = ""          // model output size (2×)
    var skipReason = ""       // why upscaling is skipped (e.g. "HDR", "source >720p-class")
}

/// Tiny `@unchecked Sendable` box to carry non-Sendable CVPixelBuffers across task/queue boundaries —
/// safe because they're treated as immutable snapshots (same pattern as the slow-mo pipeline).
private final class UpscaleBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - VideoToolbox scaler

/// One 2× super-resolution session at a fixed input size. `@unchecked Sendable`: every VT call and the
/// CoreImage conversion run on the shared serial `vtQueue` (see the thread-affinity note above).
final class SuperResolutionScaler: @unchecked Sendable {
    let width: Int
    let height: Int

    private let processor = VTFrameProcessor()
    /// Shared across instances so a rebuild's endSession is strictly ordered before the next startSession.
    private static let vtQueue = DispatchQueue(label: "com.stashy.upscale.videotoolbox")
    private var started = false
    private var failedStart = false        // don't re-run the (expensive) query/start per frame after a failure
    private var config: VTLowLatencySuperResolutionScalerConfiguration?
    private var outWidth = 0
    private var outHeight = 0
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var didLogFail = false

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Start the session + build model-conforming pools (idempotent; runs on vtQueue via callers).
    ///
    /// **Green-screen postmortem (v1.0.208):** the scale factor MUST come from
    /// `supportedScaleFactors(frameWidth:frameHeight:)` — the docs are explicit. A hardcoded `2` that the
    /// device/model doesn't support for these dimensions fails *silently*: startSession succeeds, process
    /// "succeeds", but the model never writes the destination buffer → a zeroed YUV buffer renders as a
    /// solid green screen. So: query the supported factors, pick the best ≤2, and log the whole config
    /// (factors, device max dims, pixel formats) once so ntfy shows exactly what this device accepts.
    private func startIfNeeded() -> Bool {
        if started { return true }
        if failedStart { return false }
        failedStart = true    // cleared on success below

        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            logFail("unsupported-device"); return false
        }
        let maxDims = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions   // optional
        let maxLabel = maxDims.map { "\($0.width)×\($0.height)" } ?? "?"
        let factors = VTLowLatencySuperResolutionScalerConfiguration
            .supportedScaleFactors(frameWidth: width, frameHeight: height)
        // Best supported factor ≤2 (display never needs more; keeps ANE cost sane); if the model only
        // offers larger ones, take the smallest it has. Empty list ⇒ these dimensions are unsupported.
        guard let factor = factors.filter({ $0 <= 2.001 }).max() ?? factors.min() else {
            logFail("dims-unsupported max=\(maxLabel) factors=[]")
            return false
        }
        // Even output dims (YUV requires them); the factor is the model's own, so rounding is cosmetic.
        func even(_ v: Float) -> Int { max(2, Int(v.rounded()) & ~1) }
        let ow = even(Float(width) * factor), oh = even(Float(height) * factor)

        let cfg = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: factor)
        RemoteLog.shared.event("⚙︎ upscale-cfg", [
            ("factors", factors.map { String(format: "%.2f", $0) }.joined(separator: ",")),
            ("chosen", String(format: "%.2f", factor)),
            ("max", maxLabel),
            ("srcFmt", Self.formatLabel(of: cfg.sourcePixelBufferAttributes)),
            ("dstFmt", Self.formatLabel(of: cfg.destinationPixelBufferAttributes))
        ])
        do {
            try processor.startSession(configuration: cfg)
        } catch {
            logFail("startSession:\(error)")
            return false
        }
        config = cfg
        outWidth = ow
        outHeight = oh
        sourcePool = makePool(from: cfg.sourcePixelBufferAttributes, width: width, height: height)
        destinationPool = makePool(from: cfg.destinationPixelBufferAttributes, width: ow, height: oh)
        guard sourcePool != nil, destinationPool != nil else {
            logFail("pool-nil")
            processor.endSession()
            return false
        }
        started = true
        failedStart = false
        RemoteLog.shared.event("⚙︎ upscale-start", [("in", "\(width)×\(height)"), ("out", "\(ow)×\(oh)"), ("×", String(format: "%.2f", factor))])
        return true
    }

    /// Upscale one frame. Returns the 2× buffer, or nil on any failure (caller shows the raw frame).
    func upscale(_ source: CVPixelBuffer, pts: CMTime) async -> CVPixelBuffer? {
        let input = UpscaleBox(source)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Never>) in
            Self.vtQueue.async { [self] in
                guard started || startIfNeeded() else { continuation.resume(returning: nil); return }
                guard let converted = convertToModelFormat(input.value) else {
                    logFail("convert-nil"); continuation.resume(returning: nil); return
                }
                guard let dstPool = destinationPool else { continuation.resume(returning: nil); return }
                var out: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, dstPool, &out) == kCVReturnSuccess,
                      let destination = out else { logFail("dest-buf-nil"); continuation.resume(returning: nil); return }
                guard let srcFrame = VTFrameProcessorFrame(buffer: converted, presentationTimeStamp: pts),
                      let dstFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts)
                else { logFail("frame-nil"); continuation.resume(returning: nil); return }
                let params = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: srcFrame, destinationFrame: dstFrame)

                let result = UpscaleBox(destination)
                processor.process(parameters: params, completionHandler: { [self] _, error in
                    if let error { logFail("process:\(error)"); continuation.resume(returning: nil) }
                    else { continuation.resume(returning: result.value) }
                })
            }
        }
    }

    /// End the session on the VT queue (thread-affine teardown — ending elsewhere wedges VideoToolbox).
    func invalidate() {
        Self.vtQueue.async { [self] in
            if started { processor.endSession(); started = false }
            config = nil
            sourcePool = nil
            destinationPool = nil
        }
    }

    private func makePool(from attributes: [String: Any]?, width: Int, height: Int) -> CVPixelBufferPool? {
        var merged = attributes ?? [:]
        merged[kCVPixelBufferWidthKey as String] = width
        merged[kCVPixelBufferHeightKey as String] = height
        if merged[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            merged[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        // The SR config's attributes can list SEVERAL acceptable formats (an array) — a pool needs exactly
        // one, so pick the first. (The slow-mo config pins a single format; this one is more permissive.)
        let fmtKey = kCVPixelBufferPixelFormatTypeKey as String
        if let list = merged[fmtKey] as? [Any], let first = list.first {
            merged[fmtKey] = first
        } else if merged[fmtKey] == nil {
            merged[fmtKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, merged as CFDictionary, &pool)
        return pool
    }

    /// The pixel format(s) an attributes dictionary pins, as 4-char codes — for the one-shot config log.
    private static func formatLabel(of attributes: [String: Any]?) -> String {
        guard let value = attributes?[kCVPixelBufferPixelFormatTypeKey as String] else { return "none" }
        let numbers: [NSNumber]
        if let list = value as? [NSNumber] { numbers = list }
        else if let one = value as? NSNumber { numbers = [one] }
        else { return "?" }
        return numbers.map { fourCC(OSType(truncating: $0)) }.joined(separator: "|")
    }

    /// A CoreVideo pixel-format `OSType` as its 4-character code (e.g. `'BGRA'`, `'420v'`), for diagnostics.
    private static func fourCC(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xff), UInt8((type >> 16) & 0xff),
                     UInt8((type >> 8) & 0xff), UInt8(type & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(type)"
    }

    /// BGRA → the model's required format (420v), one GPU pass. Same conversion the interpolator uses.
    private func convertToModelFormat(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = sourcePool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let destination = out else { return nil }
        ciContext.render(CIImage(cvPixelBuffer: source), to: destination)
        return destination
    }

    private func logFail(_ reason: String) {
        guard !didLogFail else { return }
        didLogFail = true
        RemoteLog.shared.event("⚙︎ upscale-fail", [("where", reason), ("in", "\(width)×\(height)")])
    }
}

// MARK: - Runner

/// Pulls decoded frames from the player's video output on a display link, upscales each (single-flight),
/// and presents the result on the reused `SlowMoRenderView` overlay.
@MainActor
final class UpscaleRunner {
    let renderView = SlowMoRenderView(frame: .zero)

    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let onTelemetry: (UpscaleTelemetry) -> Void

    private var scaler: SuperResolutionScaler?
    private var configW = 0
    private var configH = 0
    private var displayLink: CADisplayLink?
    private var inFlight = false
    private var seeded = false
    private var lastPresent = 0.0
    private var telemetry = UpscaleTelemetry()

    init(outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         onTelemetry: @escaping (UpscaleTelemetry) -> Void) {
        self.outputProvider = outputProvider
        self.onTelemetry = onTelemetry
    }

    func start() {
        telemetry.active = true
        onTelemetry(telemetry)
        let proxy = UpscaleLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(UpscaleLinkProxy.tick))
        proxy.link = link
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        scaler?.invalidate()
        scaler = nil
        telemetry.active = false
        onTelemetry(telemetry)
    }

    fileprivate func step() {
        guard let output = outputProvider() else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return }

        // Engine swap / quality switch changed the decoded size — rebuild the fixed-size session lazily.
        if scaler != nil, w != configW || h != configH, !inFlight {
            scaler?.invalidate()
            scaler = nil
        }

        if scaler == nil {
            // Runtime input gates (metadata can lie, so gate on the REAL decoded buffer). Sources above
            // 1080p-class don't need AI help (and cost too much at frame rate); the authoritative
            // dimension check is the scaler's own `supportedScaleFactors` query at session start —
            // unsupported sizes fail cleanly there and playback falls back to raw frames.
            guard w <= 1920, h <= 1920, min(w, h) <= 1100 else {
                markSkip("source >1080p-class"); present(buffer); return
            }
            let attach = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
            let transfer = (attach[kCVImageBufferTransferFunctionKey as String] as? String) ?? "?"
            let primaries = (attach[kCVImageBufferColorPrimariesKey as String] as? String) ?? "?"
            if transfer.contains("2084") || transfer.uppercased().contains("HLG") || primaries.contains("2020") {
                markSkip("HDR/wide-gamut"); present(buffer); return
            }
            scaler = SuperResolutionScaler(width: w, height: h)
            configW = w; configH = h
            telemetry.inSize = "\(w)×\(h)"
            telemetry.outSize = "…"       // real value comes from the first upscaled buffer (factor is queried)
            telemetry.skipReason = ""
            onTelemetry(telemetry)
        }

        // First frame shows immediately (raw) so engaging never blanks the video while upscale #1 runs.
        if !seeded { present(buffer); seeded = true }

        guard !inFlight, let scaler else {
            // Busy: drop this frame and hold the last upscaled one (consistent sharpness) — but never
            // freeze: if nothing has been presented for a while (wedged session), show the raw frame.
            if CACurrentMediaTime() - lastPresent > 0.25 { present(buffer) }
            return
        }
        inFlight = true
        let input = UpscaleBox((buffer, t))
        Task.detached { [weak self, scaler, input] in
            let t0 = Date()
            let out = await scaler.upscale(input.value.0, pts: input.value.1)
            let ms = Date().timeIntervalSince(t0) * 1000
            let result = UpscaleBox((out, input.value.0))
            await self?.onUpscaled(result, ms: ms)
        }
    }

    private func onUpscaled(_ result: UpscaleBox<(CVPixelBuffer?, CVPixelBuffer)>, ms: Double) {
        inFlight = false
        if let out = result.value.0 {
            present(out)
            telemetry.frames += 1
            telemetry.lastMs = ms
            telemetry.outSize = "\(CVPixelBufferGetWidth(out))×\(CVPixelBufferGetHeight(out))"
            onTelemetry(telemetry)
        } else {
            // Model failed this frame (or permanently) — show the raw frame and surface the state once.
            present(result.value.1)
            if telemetry.supported {
                telemetry.supported = false
                telemetry.skipReason = "scaler unavailable (see log)"
                onTelemetry(telemetry)
            }
        }
    }

    private func present(_ buffer: CVPixelBuffer) {
        renderView.present(buffer)
        lastPresent = CACurrentMediaTime()
    }

    private func markSkip(_ reason: String) {
        guard telemetry.skipReason != reason else { return }
        telemetry.skipReason = reason
        telemetry.supported = false
        onTelemetry(telemetry)
    }
}

/// Weak-target proxy for the runner's `CADisplayLink` (run loop retains link, link retains target).
private final class UpscaleLinkProxy: NSObject {
    weak var target: UpscaleRunner?
    var link: CADisplayLink?
    init(target: UpscaleRunner) { self.target = target; super.init() }
    @objc func tick() {
        guard let target else { link?.invalidate(); link = nil; return }
        MainActor.assumeIsolated { target.step() }
    }
}
