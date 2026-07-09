import UIKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// On-device AI video upscaling (Phase 1 — **zoom-crop**): while engaged AND the fullscreen video is
/// zoomed in, the *visible cropped region* of each decoded frame is run through VideoToolbox's
/// **low-latency super-resolution scaler** (`VTLowLatencySuperResolutionScaler`, iOS 26, Neural-Engine)
/// and presented, sharp, on a Metal overlay hosted **outside** the zoom transform (so it isn't just
/// stretched like the underlying `AVPlayerLayer`).
///
/// **Why crop, not full-frame (the 960 cap):** on-device the SR model caps its INPUT at ~960×960
/// (`maximumDimensions`). A full 1280×720 frame is already too big — `supportedScaleFactors` returns `[]`
/// and there is nothing to upscale. But when you zoom ≥~1.33×, the *visible* region is ≤960px, fits the
/// model, and native playback is soft there (the player just magnifies the same pixels) — exactly where AI
/// upscaling helps. So we feed only the visible crop and show the result over the zoomed video.
///
/// **Fixed session, variable crop:** the SR session is a fixed input size (loading an ML model per frame
/// is a non-starter — Apple's docs warn startSession "may take longer than a frame time"). The session is
/// sized from the crop's *aspect* (which equals the viewport aspect, so it's constant across zoom — see
/// `SuperResolutionScaler` for why), capped at 960 on the long side. Every frame's crop (whatever its
/// pixel size at the current zoom) is CoreImage-cropped + scaled into that fixed input, then upscaled 2×.
/// The session only rebuilds when the aspect changes (orientation flip).
///
/// **The -19730 / green-screen landmines (shared with slow-mo — same VTFrameProcessor family):**
///  • The session is thread-affine: startSession/process/endSession all on ONE serial queue (`vtQueue`).
///  • `scaleFactor` MUST come from `supportedScaleFactors(frameWidth:frameHeight:)` — a hardcoded factor
///    the model doesn't support fails *silently* (session starts, process "succeeds", but the destination
///    buffer is never written → a zeroed YUV buffer renders as a solid **green screen**).
///  • Buffers must conform to the config's own source/destination pixel-buffer attributes (biplanar 420v,
///    IOSurface-backed) — the player's BGRA frames are CoreImage-converted first.
///  • Single-flight: a frame arriving while one is processing is dropped (the overlay holds the last crop).

/// Live telemetry for the Stats overlay. All value types → Sendable.
struct UpscaleTelemetry: Sendable {
    var supported = true      // false ⇒ the scaler couldn't start / rejected input on this device
    var active = false        // runner engaged (toggle on)
    var presenting = false    // actively showing upscaled crops right now (i.e. zoomed in far enough)
    var frames = 0            // frames successfully upscaled since engaging
    var lastMs = 0.0          // wall-clock of the most recent upscale
    var inSize = ""           // fixed model input size (session)
    var outSize = ""          // model output size (input × factor)
    var skipReason = ""       // why upscaling is idle (e.g. "zoom in to upscale", "HDR")
}

/// Tiny `@unchecked Sendable` box to carry non-Sendable CVPixelBuffers across task/queue boundaries —
/// safe because they're treated as immutable snapshots (same pattern as the slow-mo pipeline).
private final class UpscaleBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - VideoToolbox scaler

/// One 2× super-resolution session at a fixed input size. `@unchecked Sendable`: every VT call and the
/// CoreImage crop/convert run on the shared serial `vtQueue` (see the thread-affinity note above).
///
/// `width`/`height` are the **fixed model input** dimensions (≤960, the crop's aspect). Each `upscale`
/// call takes a *crop rect* in the source frame's pixels; the source is cropped to it and scaled into this
/// fixed input before the model runs — so a moving/zooming crop never rebuilds the session.
final class SuperResolutionScaler: @unchecked Sendable {
    let width: Int
    let height: Int

    private let processor = VTFrameProcessor()
    /// Shared across instances so a rebuild's endSession is strictly ordered before the next startSession.
    private static let vtQueue = DispatchQueue(label: "com.stashy.upscale.videotoolbox")
    private var started = false
    private var failedStart = false        // don't re-run the (expensive) query/start per frame after a failure
    private var config: VTLowLatencySuperResolutionScalerConfiguration?
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var didLogFail = false

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Start the session + build model-conforming pools (idempotent; runs on vtQueue via callers).
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
            logFail("dims-unsupported max=\(maxLabel) factors=[] in=\(width)×\(height)")
            return false
        }
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

    /// Upscale the region of `source` bounded by `cropRect` (top-left pixel coords). The crop is scaled into
    /// this session's fixed input and run through the model. Returns the 2× buffer, or nil on any failure.
    func upscale(_ source: CVPixelBuffer, cropRect: CGRect, pts: CMTime) async -> CVPixelBuffer? {
        let input = UpscaleBox((source, cropRect))
        return await withCheckedContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Never>) in
            Self.vtQueue.async { [self] in
                guard started || startIfNeeded() else { continuation.resume(returning: nil); return }
                guard let converted = convertToModelFormat(input.value.0, cropRect: input.value.1) else {
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

    /// Crop `source` to `cropRect` (top-left pixel coords) and scale that region into the model's fixed
    /// input size + required format (420v), one GPU pass. CoreImage's origin is **bottom-left**, so the
    /// crop's Y is flipped from the UIKit-style rect the caller computes.
    private func convertToModelFormat(_ source: CVPixelBuffer, cropRect: CGRect) -> CVPixelBuffer? {
        guard let pool = sourcePool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let destination = out else { return nil }
        let sh = CGFloat(CVPixelBufferGetHeight(source))
        // Clamp the crop to the buffer and flip Y (top-left → bottom-left).
        let sw = CGFloat(CVPixelBufferGetWidth(source))
        let cx = max(0, min(cropRect.minX, sw - 2))
        let cw = max(2, min(cropRect.width, sw - cx))
        let cyTop = max(0, min(cropRect.minY, sh - 2))
        let ch = max(2, min(cropRect.height, sh - cyTop))
        let ciCrop = CGRect(x: cx, y: sh - (cyTop + ch), width: cw, height: ch)
        var image = CIImage(cvPixelBuffer: source).cropped(to: ciCrop)
        // Move the crop to the origin, then scale it up to the fixed model input size.
        image = image.transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
        image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / cw, y: CGFloat(height) / ch))
        ciContext.render(image, to: destination)
        return destination
    }

    private func logFail(_ reason: String) {
        guard !didLogFail else { return }
        didLogFail = true
        RemoteLog.shared.event("⚙︎ upscale-fail", [("where", reason), ("in", "\(width)×\(height)")])
    }
}

// MARK: - Runner

/// Pulls decoded frames on a display link, crops each to the currently-visible (zoomed) region, upscales
/// that crop (single-flight), and presents the result on a Metal overlay (`SlowMoRenderView`, reused).
///
/// The overlay is hosted OUTSIDE the player's zoom container (unlike slow-mo), so the upscaled crop shows
/// at full viewport resolution instead of being stretched by the scroll view's zoom transform.
@MainActor
final class UpscaleRunner {
    let renderView = SlowMoRenderView(frame: .zero)

    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let onTelemetry: (UpscaleTelemetry) -> Void
    /// Returns the currently-visible region of the video as a normalised (0…1) rect in frame coords, or
    /// nil when the video isn't zoomed in far enough for upscaling to help (→ overlay hides, native shows).
    /// `@MainActor` (read from `step()` on the main actor; the provider touches UIKit/scroll-view state).
    var cropProvider: (@MainActor () -> CGRect?)?

    private var scaler: SuperResolutionScaler?
    private var sessionAspect = 0.0        // input aspect the current session was built for (crop/viewport aspect)
    private var displayLink: CADisplayLink?
    private var inFlight = false
    private var presenting = false
    private var telemetry = UpscaleTelemetry()

    init(outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         onTelemetry: @escaping (UpscaleTelemetry) -> Void) {
        self.outputProvider = outputProvider
        self.onTelemetry = onTelemetry
    }

    func start() {
        telemetry.active = true
        telemetry.skipReason = "zoom in to upscale"
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
        telemetry.presenting = false
        onTelemetry(telemetry)
    }

    fileprivate func step() {
        // No zoom / not zoomed enough → hide the overlay (reveal the native, correctly-positioned video).
        guard let nrect = cropProvider?(), nrect.width > 0.02, nrect.height > 0.02 else {
            if presenting { presenting = false; telemetry.presenting = false; telemetry.skipReason = "zoom in to upscale"; onTelemetry(telemetry) }
            return
        }
        guard let output = outputProvider() else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else {
            // No new frame this tick: keep showing the last crop if we're already presenting.
            return
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return }

        // Pixel crop rect in the source frame (top-left origin). Its aspect equals the viewport aspect.
        let crop = CGRect(x: nrect.minX * CGFloat(w), y: nrect.minY * CGFloat(h),
                          width: nrect.width * CGFloat(w), height: nrect.height * CGFloat(h))
        let cropAspect = Double(crop.width / max(crop.height, 1))

        // (Re)build the fixed-size session when the aspect changes (orientation flip) — NOT on zoom, since
        // the crop's aspect is constant across zoom. Input long side capped at the model's ~960 max.
        if scaler != nil, abs(cropAspect - sessionAspect) / max(sessionAspect, 0.01) > 0.05, !inFlight {
            scaler?.invalidate(); scaler = nil
        }
        if scaler == nil {
            let attach = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
            let transfer = (attach[kCVImageBufferTransferFunctionKey as String] as? String) ?? "?"
            let primaries = (attach[kCVImageBufferColorPrimariesKey as String] as? String) ?? "?"
            if transfer.contains("2084") || transfer.uppercased().contains("HLG") || primaries.contains("2020") {
                markSkip("HDR/wide-gamut"); return
            }
            let (iw, ih) = Self.sessionInput(aspect: cropAspect)
            scaler = SuperResolutionScaler(width: iw, height: ih)
            sessionAspect = cropAspect
            telemetry.inSize = "\(iw)×\(ih)"
            telemetry.outSize = "…"
            telemetry.skipReason = ""
            onTelemetry(telemetry)
        }

        guard !inFlight, let scaler else {
            // Busy: drop this frame, hold the last crop (single-flight). No freeze risk — a paused/idle
            // display link just stops calling us; the overlay simply holds until the next result.
            return
        }
        inFlight = true
        let input = UpscaleBox((buffer, crop, t))
        Task.detached { [weak self, scaler, input] in
            let t0 = Date()
            let out = await scaler.upscale(input.value.0, cropRect: input.value.1, pts: input.value.2)
            let ms = Date().timeIntervalSince(t0) * 1000
            await self?.onUpscaled(UpscaleBox(out), ms: ms)
        }
    }

    private func onUpscaled(_ result: UpscaleBox<CVPixelBuffer?>, ms: Double) {
        inFlight = false
        if let out = result.value {
            renderView.present(out)
            telemetry.frames += 1
            telemetry.lastMs = ms
            telemetry.outSize = "\(CVPixelBufferGetWidth(out))×\(CVPixelBufferGetHeight(out))"
            if !presenting { presenting = true; telemetry.presenting = true }
            onTelemetry(telemetry)
        } else {
            // Model failed (permanently, e.g. dims unsupported) — hide the overlay so native video shows,
            // and surface the state once.
            if presenting { presenting = false; telemetry.presenting = false }
            if telemetry.supported {
                telemetry.supported = false
                telemetry.skipReason = "scaler unavailable (see log)"
            }
            onTelemetry(telemetry)
        }
    }

    private func markSkip(_ reason: String) {
        if presenting { presenting = false; telemetry.presenting = false }
        guard telemetry.skipReason != reason else { return }
        telemetry.skipReason = reason
        onTelemetry(telemetry)
    }

    /// The fixed model input size for a given crop aspect: long side capped at 960 (the model max), aspect
    /// preserved, dimensions snapped to a multiple of 8 (biplanar YUV needs even dims, and ML models often
    /// want multiples of 8/16 — snapping to 8 is a cheap hedge; the on-device `upscale-cfg` log reveals the
    /// true supported set).
    static func sessionInput(aspect: Double) -> (Int, Int) {
        func snap(_ v: Double) -> Int { max(8, Int((v / 8).rounded()) * 8) }
        let a = max(0.2, min(5.0, aspect))
        if a >= 1 { return (960, snap(960 / a)) }
        return (snap(960 * a), 960)
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
