import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// On-device AI slow-motion frame interpolation over VideoToolbox's **low-latency frame interpolation**
/// (`VTFrameProcessor`, iOS 26, Neural-Engine accelerated). Turns a pair of consecutive decoded frames —
/// `previous` → `current` — into N synthesised in-between frames, so slowed playback shows real intermediate
/// motion instead of the same frame held for several refreshes (the judder from plain `AVPlayer` rate < 1).
///
/// **Pixel-format contract (v1.0.205 — the fix for the persistent -19730):** the interpolation model does
/// NOT accept arbitrary buffers. Per WWDC 2025 session 300 ("Enhance your app with machine-learning-based
/// video effects"), source/reference/destination buffers MUST conform to the configuration's own
/// `sourcePixelBufferAttributes` / `destinationPixelBufferAttributes` — which pin a specific pixel format
/// (biplanar YUV, not BGRA), IOSurface backing, and dimensions. Feeding the model a plain 32BGRA buffer made
/// `process(parameters:)` throw `-19730 "Processor is not initialized"` at every resolution (the error is
/// misleading — the ML model just failed to build for the unsupported input). So we build both pools from the
/// config's attributes and **convert** the player's decoded BGRA frames into that format (and up to the
/// interpolation size) with CoreImage before handing them to VideoToolbox.
///
/// **Resolution cap (v1.0.206 — the real fix for -19730 at 1080p/4K):** the interpolation model has a
/// *device-specific maximum dimension* that iOS 26 exposes **no API to query** (`maximumDimensions` returns
/// nil; the query APIs only arrived in OS 27 — confirmed by an Apple engineer on the dev forums). Exceeding
/// it throws the misleading `-19730 "Processor is not initialized"` — which is why 1080p, 4K, *and* our old
/// "scale sub-1080p up to 1920×1080" workaround all failed. A developer measured the M1 Pro max at **720p**,
/// so we **cap** interpolation at 1280×720 (downscaling anything larger, preserving aspect ratio; smaller
/// content stays native) — the CoreImage pass that converts to the model format does the down-scale too. The
/// interpolated frames are then upscaled for display by the render view (aspect-fit), so output quality
/// tracks the display size, not 720p. (An earlier report of a 1280×720 *crash* was the BGRA-format bug — now
/// that we feed the model its required 420v format, 720p is within the supported window.)
///
/// Concurrency: `@unchecked Sendable`. All VideoToolbox calls (`startSession` + `process`) and the CoreImage
/// conversions run on a dedicated serial queue (`vtQueue`) so the session's state/pools are never touched
/// concurrently, and startSession + process share one thread (the session is context-affine). The caller
/// (`SlowMoRunner`) additionally issues **one** `interpolate` at a time (single-flight).

/// A tiny `@unchecked Sendable` wrapper to carry non-`Sendable` values (CVPixelBuffers) across the
/// dispatch-queue / continuation boundary — safe because they're immutable snapshots here.
private final class SlowMoBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class SlowMoInterpolator: @unchecked Sendable {
    /// The decoded source size handed in by the caller.
    let nativeWidth: Int
    let nativeHeight: Int
    /// The size interpolation actually runs at (native, or downscaled to stay under the model's max dimension).
    let width: Int
    let height: Int
    /// True when frames are scaled from native → interpolation size.
    let scaled: Bool
    /// Max synthesised frames per source pair (session config). 3 → 4× (mids at 0.25/0.5/0.75) for silky
    /// slow-mo (source-fps smoothness at 0.25×, ~2× source at 0.5×). Pure-temporal, so >1 phase is allowed.
    let interpolatedFrames: Int

    /// The interpolation phases for this session — evenly spaced in (0,1), matching `interpolatedFrames`
    /// (e.g. 3 → `[0.25, 0.5, 0.75]`). Callers pass this straight to `interpolate(phases:)`.
    var phases: [Double] {
        (1...interpolatedFrames).map { Double($0) / Double(interpolatedFrames + 1) }
    }

    private let processor = VTFrameProcessor()
    /// VideoToolbox's frame-processor session is **thread-affine** — `startSession`, `process`, AND
    /// `endSession` must all run on the same thread (Swift concurrency hops threads across `await`, which
    /// throws -19730; ending on the wrong thread corrupts VT's per-process state → crash or a wedged
    /// processor). So every VT call — plus the CoreImage conversion — is serialised here. **Static/shared**
    /// across all interpolator instances so that when the factor changes and we swap instances, the old
    /// session's `endSession` is strictly ordered *before* the new session's `startSession` (a per-instance
    /// queue would let them race across threads). Single-flight upstream means only one runs at a time anyway.
    private static let vtQueue = DispatchQueue(label: "com.stashy.slowmo.videotoolbox")
    private var started = false
    private var config: VTLowLatencyFrameInterpolationConfiguration?   // retained for the session's lifetime
    /// Source/reference frame pool — built from the config's REQUIRED `sourcePixelBufferAttributes` (correct
    /// pixel format + IOSurface), NOT hardcoded BGRA. Player frames are CoreImage-converted into this format.
    private var sourcePool: CVPixelBufferPool?
    /// Synthesised-output pool — built from the config's `destinationPixelBufferAttributes`. VideoToolbox
    /// writes the interpolated frames into these.
    private var destinationPool: CVPixelBufferPool?
    /// Reused for BGRA→(model format) conversion + up-scale. Thread-safe; created once.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var loggedConfig = false

    init(width: Int, height: Int, interpolatedFrames: Int = 1) {
        self.nativeWidth = width
        self.nativeHeight = height
        let safe = Self.safeInterpolationSize(width: width, height: height)
        self.width = safe.width
        self.height = safe.height
        self.scaled = (safe.width != width || safe.height != height)
        self.interpolatedFrames = max(1, interpolatedFrames)
    }

    /// The resolution to actually interpolate at. The model has a device-specific max dimension (~720p on
    /// M1 Pro) that iOS 26 can't query; exceeding it throws -19730. So cap the frame so neither side exceeds
    /// **1280×720** (long side ≤ 1280, short side ≤ 720), preserving aspect ratio and rounding to even
    /// dimensions (biplanar YUV requires even width/height). Content already within the cap stays native.
    static func safeInterpolationSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1280, 720) }
        let longMax = 1280.0, shortMax = 720.0
        let longSide = Double(max(width, height)), shortSide = Double(min(width, height))
        let factor = min(1.0, longMax / longSide, shortMax / shortSide)
        if factor >= 1.0 { return (width, height) }
        func even(_ v: Double) -> Int { max(2, Int((v).rounded()) & ~1) }
        return (even(Double(width) * factor), even(Double(height) * factor))
    }

    /// Start the VideoToolbox session and build the model-conforming pools (idempotent). Returns `false` if
    /// the effect isn't available / the pools can't be built — the caller then falls back to plain slow play.
    @discardableResult
    func startIfNeeded() -> Bool {
        if started { return true }
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: interpolatedFrames)
        else { logFail("cfg-nil"); return false }

        // Log the pixel format the model requires (once) — read from the config's own source attributes,
        // the dictionary whose format we now conform to. Makes any future format mismatch obvious. (Read via
        // a tolerant `[String: Any]?` coercion; the dictionary properties bridge from `NSDictionary`.)
        if !loggedConfig {
            loggedConfig = true
            let srcAttrs: [String: Any]? = cfg.sourcePixelBufferAttributes
            let dstAttrs: [String: Any]? = cfg.destinationPixelBufferAttributes
            let srcFmt = (srcAttrs?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)
                .map { Self.fourCC(OSType(truncating: $0)) } ?? "?"
            let dstFmt = (dstAttrs?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)
                .map { Self.fourCC(OSType(truncating: $0)) } ?? "?"
            RemoteLog.shared.event("⚙︎ slowmo-cfg", [
                ("srcFmt", srcFmt), ("dstFmt", dstFmt),
                ("srcAttrs", srcAttrs != nil ? "\(srcAttrs!.count)k" : "nil"),
                ("interp", "\(width)×\(height)")
            ])
        }
        do {
            try processor.startSession(configuration: cfg)
            config = cfg          // keep the configuration alive for the session's lifetime
            sourcePool = makePool(from: cfg.sourcePixelBufferAttributes)
            destinationPool = makePool(from: cfg.destinationPixelBufferAttributes)
            guard sourcePool != nil, destinationPool != nil else {
                logFail("pool-nil")
                processor.endSession()
                return false
            }
            started = true
            return true
        } catch {
            logFail("startSession:\(error)")
            return false
        }
    }

    /// Build an IOSurface-backed pixel-buffer pool that conforms to the model's required attributes.
    /// Starts from the config's own attribute dictionary (which carries the required pixel format) and just
    /// pins our interpolation dimensions + IOSurface backing on top.
    private func makePool(from attributes: [String: Any]?) -> CVPixelBufferPool? {
        var merged = attributes ?? [:]
        merged[kCVPixelBufferWidthKey as String] = width
        merged[kCVPixelBufferHeightKey as String] = height
        if merged[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            merged[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        // Fallback only if the config didn't pin a format: a biplanar 420 (typical ML-model input).
        if merged[kCVPixelBufferPixelFormatTypeKey as String] == nil {
            merged[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, merged as CFDictionary, &pool)
        return pool
    }

    /// Synthesise `phases.count` frames between `previous` and `current`. Phases are fractions in (0,1) from
    /// the previous frame (0) to the current one (1) — e.g. `[0.5]` for one mid frame. Returns the synthesised
    /// buffers (at the interpolation size, in the model's format) in phase order, or `[]` on any failure.
    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime,
                     current: CVPixelBuffer, currentPTS: CMTime,
                     phases: [Double]) async -> [CVPixelBuffer] {
        let inputs = SlowMoBox((previous, current))   // carry the non-Sendable buffers onto the VT queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<[CVPixelBuffer], Never>) in
            Self.vtQueue.async { [self] in
                let previous = inputs.value.0, current = inputs.value.1
                // startSession + process must run in this one block (same thread) or process throws -19730.
                guard started || startIfNeeded() else { logFail("no-session"); continuation.resume(returning: []); return }
                // Convert the player's BGRA frames into the model's required format (and up to the crash-safe
                // interpolation size) — the model rejects raw BGRA, which is what threw -19730 before.
                guard let previousSized = convertToModelFormat(previous),
                      let currentSized  = convertToModelFormat(current)
                else { logFail("convert-nil"); continuation.resume(returning: []); return }
                guard let previousFrame = VTFrameProcessorFrame(buffer: previousSized, presentationTimeStamp: previousPTS),
                      let currentFrame = VTFrameProcessorFrame(buffer: currentSized, presentationTimeStamp: currentPTS)
                else { logFail("frame-nil"); continuation.resume(returning: []); return }

                let span = currentPTS - previousPTS
                var destinations: [CVPixelBuffer] = []
                var destinationFrames: [VTFrameProcessorFrame] = []
                for phase in phases {
                    guard let buffer = makeDestinationBuffer() else { logFail("dest-buf-nil"); continuation.resume(returning: []); return }
                    let pts = previousPTS + CMTimeMultiplyByFloat64(span, multiplier: phase)
                    guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else { logFail("dest-frame-nil"); continuation.resume(returning: []); return }
                    destinations.append(buffer)
                    destinationFrames.append(frame)
                }
                guard let parameters = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: currentFrame, previousFrame: previousFrame,
                    interpolationPhase: phases.map { Float($0) }, destinationFrames: destinationFrames)
                else { logFail("params-nil"); continuation.resume(returning: []); return }

                let outputs = SlowMoBox(destinations)
                // Completion-handler process() (not the async form) so it's invoked on THIS thread, right
                // after startSession — the completion fires on VT's own queue and just resumes us.
                processor.process(parameters: parameters, completionHandler: { [self] _, error in
                    if let error { logFail("process:\(error)"); continuation.resume(returning: []) }
                    else { continuation.resume(returning: outputs.value) }
                })
            }
        }
    }

    /// Log the first interpolation failure point (once) off-device — pins down why `synthesized` stays 0
    /// (e.g. a `process` throw naming an unsupported pixel format).
    private var didLogFail = false
    private func logFail(_ reason: String) {
        guard !didLogFail else { return }
        didLogFail = true
        RemoteLog.shared.event("⚙︎ slowmo-fail", [
            ("where", reason),
            ("interp", "\(width)×\(height)"),
            ("native", "\(nativeWidth)×\(nativeHeight)")
        ])
    }

    /// End the session and drop the pools — **on the shared VT queue** so `endSession` runs on the same
    /// thread as `startSession`/`process` (ending on the caller's thread, e.g. the main actor on a rate
    /// change or dealloc, corrupts VideoToolbox → crash/wedge). The `[self]` capture keeps the instance alive
    /// until the block runs, so the object is released *from the queue* → its deinit is queue-thread too.
    func invalidate() {
        Self.vtQueue.async { [self] in
            if started { processor.endSession(); started = false }
            config = nil
            sourcePool = nil
            destinationPool = nil
        }
    }

    /// Convert a native decoded frame (any format, typically 32BGRA from `AVPlayerItemVideoOutput`) into a
    /// source-pool buffer that conforms to the model's required pixel format, up-scaled to the interpolation
    /// size when needed. CoreImage does the format conversion (BGRA→YUV) and the scale in one GPU pass.
    private func convertToModelFormat(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = sourcePool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let destination = out else { return nil }
        var image = CIImage(cvPixelBuffer: source)
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        if sw != width || sh != height {
            image = image.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(sw), y: CGFloat(height) / CGFloat(sh)))
        }
        ciContext.render(image, to: destination)
        return destination
    }

    /// Allocate one output buffer from the model's destination pool (VideoToolbox writes into it).
    private func makeDestinationBuffer() -> CVPixelBuffer? {
        guard let pool = destinationPool else { return nil }
        var buffer: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess
            ? buffer : nil
    }

    /// A CoreVideo pixel-format `OSType` as its 4-character code (e.g. `'BGRA'`, `'420v'`), for diagnostics.
    private static func fourCC(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xff), UInt8((type >> 16) & 0xff),
                     UInt8((type >> 8) & 0xff), UInt8(type & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(type)"
    }
}
