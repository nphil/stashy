import UIKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import MetalFX
import MetalKit
import VideoToolbox

/// On-device AI/GPU video upscaling, v2 — **MetalFX zoom-crop** (the VT-neural full-frame and live
/// zoom-crop attempts are dead ends on iOS 26; see the postmortem below).
///
/// **How it works now:** while the toggle is on and the fullscreen video is zoomed past ~1.3×, every
/// decoded frame is upscaled **full-frame, 2×** by `MTLFXSpatialScaler` (Apple's game upscaler — edge/
/// pattern-aware, GPU, ~2 ms/frame at 720p→1440p, **no input-size cap, no per-size session**). A Metal
/// overlay hosted OUTSIDE the zoom transform then draws just the *visible crop* of that pre-upscaled
/// frame, re-rendering **every display tick** with live gesture geometry — so pan/pinch stay 120 Hz
/// smooth even though video frames arrive at 24–30 fps. Below the zoom threshold the overlay hides
/// (UIKit `isHidden`, no SwiftUI tree churn) and the native `AVPlayerLayer` shows through.
///
/// **Postmortem — why not `VTLowLatencySuperResolutionScaler` live (v1.0.241):**
///  • Its input caps at **960×960 on-device** (`maximumDimensions`), so full-frame 720p+ is impossible.
///  • It needs a **fixed input size per session** and Apple warns session start (an ML model load) "may
///    take longer than a frame time". A live zoom crop is *continuously variable* — the visible rect is
///    the viewport∩video intersection, whose aspect changes as you pan near edges — which caused a
///    session-rebuild storm (3 rebuilds in 650 ms in the field logs): stutter, 280 MB memory churn,
///    and it raced pinch. Pre-scaling the crop to a fixed 960-wide input also fed the model bilinear
///    blur, erasing its quality gain. Structural mismatch, not a tuning problem.
///  • Green-screen landmine (kept for the paused-still phase): the scale factor MUST come from
///    `supportedScaleFactors(frameWidth:frameHeight:)` — an unsupported factor fails silently and the
///    zeroed YUV destination renders solid green. And the session is thread-affine (one serial queue).
/// The neural scaler returns in the **pause-to-enhance** phase (one-shot on the paused frame's native
/// crop pixels — no gestures racing, no rebuild storms). iOS 27 (OS 27) adds proper capability-query
/// APIs — revisit then (see ROADMAP).
///
/// **Frame-tap etiquette:** this runner and AI slow-mo share the engine's one `AVPlayerItemVideoOutput`,
/// and `copyPixelBuffer` consumes frames — two live consumers steal from each other. So the model layer
/// keeps them mutually exclusive (slow-mo wins at ≤0.5×; this runner re-engages above).

/// Live telemetry for the Stats overlay. All value types → Sendable.
struct UpscaleTelemetry: Sendable {
    var supported = true      // false ⇒ upscaler unavailable on this device/input
    var active = false        // runner engaged (toggle on)
    var presenting = false    // actively showing upscaled crops right now (zoomed in far enough)
    var mode = ""             // "MetalFX 2×" while live; "Neural 2× (still)" when the paused enhance lands
    var frames = 0            // full frames upscaled since engaging
    var lastMs = 0.0          // wall-clock of the most recent full-frame upscale
    var inSize = ""           // source frame size
    var outSize = ""          // upscaled frame size
    var skipReason = ""       // why upscaling is idle (e.g. "zoom in to upscale", "HDR")
}

/// The live zoom geometry the overlay needs, computed by the zoom surface's coordinator each tick.
struct UpscaleGeometry {
    /// Visible region of the video, normalised 0…1 in frame coords (top-left origin).
    let videoCrop: CGRect
    /// Where that region sits in the viewport, in points (top-left origin, overlay-local).
    let placement: CGRect
    /// The overlay's size in points (== the zoom surface's size).
    let viewportSize: CGSize
}

/// Tiny `@unchecked Sendable` box to carry non-Sendable CVPixelBuffers across task/queue boundaries —
/// safe because they're treated as immutable snapshots (same pattern as the slow-mo pipeline).
private final class UpscaleBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Neural still enhancer (pause-to-enhance)

/// One `VTLowLatencySuperResolutionScaler` session at a fixed input size, used **one-shot** on the
/// paused frame's visible crop — the only place the neural model is structurally sound on iOS 26 (fixed
/// dims per session + slow model load make it wrong for live zoom; see the file-header postmortem).
/// `@unchecked Sendable`: every VT call and the CoreImage conversion run on the shared serial `vtQueue`
/// (the session is thread-affine — startSession/process/endSession must share one thread).
final class SuperResolutionScaler: @unchecked Sendable {
    let width: Int
    let height: Int

    private let processor = VTFrameProcessor()
    /// Shared across instances so one shot's endSession is strictly ordered before the next startSession.
    private static let vtQueue = DispatchQueue(label: "com.stashy.upscale.videotoolbox")
    private var started = false
    private var failedStart = false
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
    /// **Green-screen landmine:** the scale factor MUST come from `supportedScaleFactors` — a hardcoded
    /// unsupported factor fails silently and the zeroed YUV destination renders as a solid green frame.
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
        guard let factor = factors.filter({ $0 <= 2.001 }).max() ?? factors.min() else {
            logFail("dims-unsupported max=\(maxLabel) factors=[] in=\(width)×\(height)")
            return false
        }
        func even(_ v: Float) -> Int { max(2, Int(v.rounded()) & ~1) }
        let ow = even(Float(width) * factor), oh = even(Float(height) * factor)

        let cfg = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: factor)
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
        RemoteLog.shared.event("⚙︎ upscale-still", [("in", "\(width)×\(height)"), ("out", "\(ow)×\(oh)"), ("×", String(format: "%.2f", factor))])
        return true
    }

    /// Upscale the region of `source` bounded by `cropRect` (top-left pixel coords, ≈ this session's
    /// input size — the model sees the crop's native pixels). Returns the upscaled buffer, or nil.
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
        // The SR config can list SEVERAL acceptable formats (an array) — a pool needs exactly one.
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

    /// Crop `source` to `cropRect` (top-left pixel coords) and render that region into the model's input
    /// buffer (format conversion + the tiny /8-rounding resample in one GPU pass). CoreImage's origin is
    /// **bottom-left**, so the crop's Y is flipped from the UIKit-style rect the caller computes.
    private func convertToModelFormat(_ source: CVPixelBuffer, cropRect: CGRect) -> CVPixelBuffer? {
        guard let pool = sourcePool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let destination = out else { return nil }
        let sw = CGFloat(CVPixelBufferGetWidth(source))
        let sh = CGFloat(CVPixelBufferGetHeight(source))
        let cx = max(0, min(cropRect.minX, sw - 2))
        let cw = max(2, min(cropRect.width, sw - cx))
        let cyTop = max(0, min(cropRect.minY, sh - 2))
        let ch = max(2, min(cropRect.height, sh - cyTop))
        let ciCrop = CGRect(x: cx, y: sh - (cyTop + ch), width: cw, height: ch)
        var image = CIImage(cvPixelBuffer: source).cropped(to: ciCrop)
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

// MARK: - MetalFX full-frame upscaler

/// Wraps one `MTLFXSpatialScaler` at a fixed input→output size (rebuilt only when the DECODED size
/// changes — never on zoom/pan, which is what makes this stable where the VT approach wasn't).
/// Main-actor: encoding is ~0.1 ms of CPU; the GPU does the work asynchronously on `queue`.
@MainActor
final class MetalFXFrameUpscaler {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scaler: any MTLFXSpatialScaler
    private var textureCache: CVMetalTextureCache?
    /// Output is a BGRA, IOSurface-backed pixel buffer pool so the render view can present it through the
    /// same proven CIImage(cvPixelBuffer:) path as every other frame in the app (no Metal-vs-CI flip games).
    private var outputPool: CVPixelBufferPool?
    /// Keep recently-encoded CVMetalTexture wrappers alive until the GPU is long done with them (the
    /// command buffer retains the MTLTextures, but the cache wrappers must outlive the read too).
    private var recentTextures: [CVMetalTexture] = []

    /// nil when MetalFX spatial scaling isn't supported on this GPU (very old devices) or setup fails.
    init?(inputWidth: Int, inputHeight: Int, device: MTLDevice, queue: MTLCommandQueue) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = inputWidth * 2
        self.outputHeight = inputHeight * 2
        self.device = device
        self.queue = queue

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputWidth
        desc.inputHeight = inputHeight
        desc.outputWidth = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual   // SDR video frames are sRGB-encoded
        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }
        scaler.inputContentWidth = inputWidth
        scaler.inputContentHeight = inputHeight
        self.scaler = scaler

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &outputPool)
        guard textureCache != nil, outputPool != nil else { return nil }
    }

    /// Upscale one full BGRA frame 2×. Encodes on the shared queue and returns the OUTPUT pixel buffer
    /// immediately — the caller renders it via the same queue, so Metal's ordering guarantees the scaler
    /// pass completes first (no CPU sync needed).
    func upscale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let cache = textureCache, let pool = outputPool else { return nil }
        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer) == kCVReturnSuccess,
              let output = outBuffer else { return nil }

        // MetalFX writes its output via render-target usage; ask the wrapper textures for it explicitly.
        let usageAttrs = [kCVMetalTextureUsage as String:
                            NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)] as CFDictionary
        var cvIn: CVMetalTexture?
        var cvOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, source, nil, .bgra8Unorm,
                                                  inputWidth, inputHeight, 0, &cvIn)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, output, usageAttrs, .bgra8Unorm,
                                                  outputWidth, outputHeight, 0, &cvOut)
        guard let cvIn, let cvOut,
              let inTex = CVMetalTextureGetTexture(cvIn),
              let outTex = CVMetalTextureGetTexture(cvOut),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        scaler.colorTexture = inTex
        scaler.outputTexture = outTex
        scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()

        // Ring-retain the wrappers for a few frames (GPU latency ≪ 4 video frames at 24–30 fps).
        recentTextures.append(cvIn)
        recentTextures.append(cvOut)
        if recentTextures.count > 8 { recentTextures.removeFirst(recentTextures.count - 8) }
        return output
    }
}

// MARK: - MetalFX pass 2 (crop refine)

/// Second MetalFX pass **on the visible crop** of the pass-1 output. One 2× pass diluted by a big
/// bilinear stretch to the viewport looked barely different from Lanczos (the v1.0.243 feedback) —
/// chaining a second 2× on just the crop closes most of that gap (effective 4× from the source at deep
/// zoom, so the viewport gets scaled pixels instead of stretch).
///
/// The scaler's textures are a **fixed canvas** (rebuild-free — the VT lesson); the variable crop is
/// CI-copied into the canvas each pass and its true size set via `inputContentWidth/Height` (the
/// game-style dynamic-resolution mechanism, designed to change per frame).
@MainActor
final class MetalFXCropUpscaler {
    let canvasWidth: Int
    let canvasHeight: Int
    let outWidth: Int
    let outHeight: Int

    private let queue: MTLCommandQueue
    private let scaler: any MTLFXSpatialScaler
    private let ciContext: CIContext
    private var inputBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var outputPool: CVPixelBufferPool?
    private var recentTextures: [CVMetalTexture] = []

    init?(canvasWidth: Int, canvasHeight: Int, device: MTLDevice, queue: MTLCommandQueue) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.outWidth = canvasWidth * 2
        self.outHeight = canvasHeight * 2
        self.queue = queue
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = canvasWidth
        desc.inputHeight = canvasHeight
        desc.outputWidth = outWidth
        desc.outputHeight = outHeight
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual
        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }
        self.scaler = scaler

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        // Reusable input canvas (single buffer — same-queue ordering serialises write-after-read), and
        // an output pool (results are held by the presenter across ticks, so those must rotate).
        let inAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvasWidth,
            kCVPixelBufferHeightKey as String: canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var inBuf: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, canvasWidth, canvasHeight, kCVPixelFormatType_32BGRA,
                            inAttrs as CFDictionary, &inBuf)
        let outAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outWidth,
            kCVPixelBufferHeightKey as String: outHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, outAttrs as CFDictionary, &outputPool)
        guard let inBuf, textureCache != nil, outputPool != nil else { return nil }
        inputBuffer = inBuf
    }

    /// Refine `cropPx` (pixel rect in `frame`, top-left origin) with a second 2× pass. Returns the output
    /// buffer and the content rect within it (top-left origin) holding the 2× crop. nil ⇒ caller falls
    /// back to presenting the pass-1 frame directly.
    func refine(frame: CVPixelBuffer, cropPx: CGRect) -> (buffer: CVPixelBuffer, content: CGRect)? {
        guard let cache = textureCache, let pool = outputPool, let inBuf = inputBuffer else { return nil }
        let fw = CGFloat(CVPixelBufferGetWidth(frame)), fh = CGFloat(CVPixelBufferGetHeight(frame))
        // Integer, even, clamped crop that must fit the canvas.
        let cw = min(CGFloat(canvasWidth), (cropPx.width / 2).rounded(.up) * 2)
        let ch = min(CGFloat(canvasHeight), (cropPx.height / 2).rounded(.up) * 2)
        let cx = max(0, min(cropPx.minX.rounded(), fw - cw))
        let cy = max(0, min(cropPx.minY.rounded(), fh - ch))
        guard cw >= 32, ch >= 32 else { return nil }

        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer) == kCVReturnSuccess,
              let output = outBuffer else { return nil }

        let usageAttrs = [kCVMetalTextureUsage as String:
                            NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead, .shaderWrite]).rawValue)] as CFDictionary
        var cvIn: CVMetalTexture?
        var cvOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, inBuf, usageAttrs, .bgra8Unorm,
                                                  canvasWidth, canvasHeight, 0, &cvIn)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, output, usageAttrs, .bgra8Unorm,
                                                  outWidth, outHeight, 0, &cvOut)
        guard let cvIn, let cvOut,
              let inTex = CVMetalTextureGetTexture(cvIn),
              let outTex = CVMetalTextureGetTexture(cvOut),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        // 1) Copy the crop into the canvas at the origin (CI, on OUR command buffer so pass ordering holds).
        //    CI's origin is bottom-left: content at extent-origin lands at the canvas' BOTTOM; mirror that
        //    when telling MetalFX where the content is? No — MetalFX content regions anchor at texture
        //    (0,0) = TOP-left. So place the crop at the TOP of the canvas: CI y-origin = canvasH - ch.
        let src = CIImage(cvPixelBuffer: frame)
        let ciCrop = CGRect(x: cx, y: fh - (cy + ch), width: cw, height: ch)
        let placed = src.cropped(to: ciCrop)
            .transformed(by: CGAffineTransform(translationX: -ciCrop.minX,
                                               y: CGFloat(canvasHeight) - ch - ciCrop.minY))
        ciContext.render(placed, to: inTex, commandBuffer: commandBuffer,
                         bounds: CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight)),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        // 2) Scale: content region (top-left anchored) → 2× at the output's top-left.
        scaler.inputContentWidth = Int(cw)
        scaler.inputContentHeight = Int(ch)
        scaler.colorTexture = inTex
        scaler.outputTexture = outTex
        scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()

        recentTextures.append(cvIn)
        recentTextures.append(cvOut)
        if recentTextures.count > 8 { recentTextures.removeFirst(recentTextures.count - 8) }
        return (output, CGRect(x: 0, y: 0, width: cw * 2, height: ch * 2))
    }
}

// MARK: - Crop render view

/// Minimal Metal view that draws a *crop* of the latest upscaled frame into a *placement rect*, both
/// supplied per-draw — same MTKView + CIContext plumbing as `SlowMoRenderView`, but purpose-built for
/// the upscale overlay (transparent outside the placement so letterbox areas show through).
@MainActor
final class UpscaleCropRenderView: UIView, MTKViewDelegate {
    private let mtkView: MTKView
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    let metalDevice: MTLDevice

    private var currentImage: CIImage?     // full upscaled frame
    private var cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)   // normalised, top-left origin
    private var placement = CGRect.zero    // in view points, top-left origin

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()!
        metalDevice = device
        commandQueue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        mtkView = MTKView(frame: .zero, device: device)
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        mtkView.framebufferOnly = false
        mtkView.isPaused = true                   // driven manually from present()
        mtkView.enableSetNeedsDisplay = false
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.delegate = self
        mtkView.isOpaque = false
        mtkView.layer.isOpaque = false
        mtkView.colorPixelFormat = .bgra8Unorm
        // Transparent clear so areas outside the placement rect show the native video/letterbox through.
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        addSubview(mtkView)
    }

    /// The command queue the upscaler must share so scaler→draw ordering is guaranteed by Metal.
    var sharedQueue: MTLCommandQueue { commandQueue }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Unsharp-mask intensity applied to the composited output (0 = off). Set per-present by the runner:
    /// on for MetalFX live frames (restores the "pop" a conservative spatial scaler lacks), off for the
    /// neural still (already crisp; sharpening it invites halos).
    private var sharpenAmount: Double = 0

    /// Draw `cropNorm` (normalised, top-left origin) of `frame` into `placement` (view points) now.
    func present(frame: CVPixelBuffer, cropNorm: CGRect, placement: CGRect, sharpen: Double = 0) {
        currentImage = CIImage(cvPixelBuffer: frame)
        self.cropNorm = cropNorm
        self.placement = placement
        self.sharpenAmount = sharpen
        mtkView.draw()
    }

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let target = view.drawableSize
        guard target.width > 0, target.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let px = target.width / bounds.width      // points → drawable pixels
        let py = target.height / bounds.height

        // Crop in image pixels. CIImage's origin is bottom-left, cropNorm's is top-left → flip Y.
        let iw = image.extent.width, ih = image.extent.height
        let crop = CGRect(x: cropNorm.minX * iw,
                          y: ih - (cropNorm.minY + cropNorm.height) * ih,
                          width: cropNorm.width * iw,
                          height: cropNorm.height * ih).intersection(image.extent)
        guard crop.width > 1, crop.height > 1 else { return }

        // Placement in drawable pixels, bottom-left origin (flip Y from the view's top-left rect).
        let dest = CGRect(x: placement.minX * px,
                          y: target.height - (placement.minY + placement.height) * py,
                          width: placement.width * px,
                          height: placement.height * py)

        var scaled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: dest.width / crop.width,
                                               y: dest.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: dest.minX, y: dest.minY))
        // Display-resolution unsharp mask (clamped so edge pixels don't fringe against transparency).
        if sharpenAmount > 0.01 {
            let extent = scaled.extent
            scaled = scaled.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 2.0,
                    kCIInputIntensityKey: sharpenAmount
                ])
                .cropped(to: extent)
        }

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        if GPUProbe.active {
            commandBuffer.addCompletedHandler { cb in
                GPUTimeAccumulator.shared.record(cb.gpuEndTime - cb.gpuStartTime)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - Runner

/// Drives the live MetalFX zoom-crop pipeline on a display link:
///  • per NEW video frame: full-frame 2× MetalFX upscale (≈2 ms GPU),
///  • per DISPLAY tick: redraw the visible crop of the latest upscaled frame with live gesture geometry.
/// Visibility is pure UIKit (`renderView.isHidden`) so engaging/disengaging never touches the SwiftUI
/// tree mid-gesture (inserting/removing the overlay per zoom threshold is what raced pinch in v1.0.241).
@MainActor
final class UpscaleRunner {
    let renderView = UpscaleCropRenderView(frame: .zero)

    private let outputProvider: () -> AVPlayerItemVideoOutput?
    private let onTelemetry: (UpscaleTelemetry) -> Void
    /// Live zoom geometry from the zoom surface's coordinator; nil when not zoomed in far enough.
    var geometryProvider: (@MainActor () -> UpscaleGeometry?)?
    /// True while playback is paused — arms the one-shot neural enhance of the visible crop.
    var pausedProvider: (@MainActor () -> Bool)?

    private var upscaler: MetalFXFrameUpscaler?
    private var upscalerFailed = false
    private var displayLink: CADisplayLink?
    private var latestUpscaled: CVPixelBuffer?
    private var lastRawBuffer: CVPixelBuffer?      // raw decoded frame, the neural still's input
    private var telemetry = UpscaleTelemetry()

    // MetalFX pass 2 (crop refine): result cached per (frame, geometry) so static playback re-presents
    // without re-encoding, while pans/new frames re-refine.
    private var cropUpscaler: MetalFXCropUpscaler?
    private var cropUpscalerFailed = false
    private var pass2Buffer: CVPixelBuffer?
    private var pass2Content = CGRect.zero
    private var pass2Geometry: UpscaleGeometry?
    private var pass2FrameStamp = 0                // ingest counter the cached pass-2 was refined from
    private var frameStamp = 0                     // bumps on every newly-ingested video frame

    // Pause-to-enhance state: the neural still, valid only for the exact geometry it was rendered at.
    private var stillBuffer: CVPixelBuffer?
    private var stillGeometry: UpscaleGeometry?
    private var stillTask: Task<Void, Never>?
    private var stillTriedGeometry: UpscaleGeometry?   // don't relaunch for a geometry that already ran/skipped
    private var lastGeometry: UpscaleGeometry?
    private var geometryStableSince = 0.0
    private var wasPaused = false

    init(outputProvider: @escaping () -> AVPlayerItemVideoOutput?,
         onTelemetry: @escaping (UpscaleTelemetry) -> Void) {
        self.outputProvider = outputProvider
        self.onTelemetry = onTelemetry
    }

    func start() {
        renderView.isHidden = true
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
        upscaler = nil
        cropUpscaler = nil
        pass2Buffer = nil
        pass2Geometry = nil
        latestUpscaled = nil
        lastRawBuffer = nil
        stillTask?.cancel()
        stillTask = nil
        stillBuffer = nil
        stillGeometry = nil
        renderView.isHidden = true
        telemetry.active = false
        telemetry.presenting = false
        onTelemetry(telemetry)
    }

    fileprivate func step() {
        // Not zoomed in far enough → hide the overlay (UIKit-only; the native video shows through).
        guard let geo = geometryProvider?(),
              geo.videoCrop.width > 0.01, geo.videoCrop.height > 0.01,
              geo.placement.width > 1, geo.placement.height > 1 else {
            dropStill()
            setPresenting(false, reason: "zoom in to upscale")
            return
        }
        let paused = pausedProvider?() ?? false
        // A fresh pause re-arms the enhance even at identical geometry (pause → play → pause retries).
        if paused, !wasPaused { stillTriedGeometry = nil }
        wasPaused = paused

        // Geometry stability (arms the paused enhance only once the gesture has settled).
        if let last = lastGeometry, Self.approxEqual(last, geo) {
            // still stable
        } else {
            geometryStableSince = CACurrentMediaTime()
            stillTriedGeometry = nil
        }
        lastGeometry = geo

        // A neural still is only valid for the exact geometry it was rendered at, and only while paused.
        if stillBuffer != nil, let sg = stillGeometry, !paused || !Self.approxEqual(sg, geo) {
            dropStill()
        }

        // Pull a newly-decoded frame if there is one; otherwise keep re-drawing the last upscaled frame
        // with fresh geometry (this is what keeps pan/pinch 120 Hz-smooth between 24–30 fps video frames).
        if let output = outputProvider() {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t),
               let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                ingest(buffer)
            }
        }

        // Paused + settled + nothing running → fire the one-shot neural enhance of the visible crop.
        if paused, stillBuffer == nil, stillTask == nil, stillTriedGeometry == nil,
           CACurrentMediaTime() - geometryStableSince > 0.35, let raw = lastRawBuffer {
            launchStillEnhance(geometry: geo, raw: raw)
        }

        // Present: the neural still wins while it matches the live geometry; else the refined (pass-2)
        // crop when the zoom is deep enough for it; else the pass-1 frame.
        if paused, let still = stillBuffer, let sg = stillGeometry, Self.approxEqual(sg, geo) {
            renderView.present(frame: still, cropNorm: CGRect(x: 0, y: 0, width: 1, height: 1),
                               placement: geo.placement, sharpen: 0)
            setPresenting(true, reason: "")
        } else if let frame = latestUpscaled {
            if let refined = refinedCrop(of: frame, geometry: geo) {
                renderView.present(frame: refined.buffer, cropNorm: refined.cropNorm,
                                   placement: geo.placement, sharpen: 0.45)
                setMode("MetalFX 4× (crop)")
            } else {
                renderView.present(frame: frame, cropNorm: geo.videoCrop,
                                   placement: geo.placement, sharpen: 0.45)
                setMode("MetalFX 2×")
            }
            setPresenting(true, reason: "")
        }
    }

    private func setMode(_ mode: String) {
        guard telemetry.mode != mode else { return }
        telemetry.mode = mode
        onTelemetry(telemetry)
    }

    /// MetalFX pass 2 over the visible crop of the pass-1 output — the fix for "one 2× pass diluted by a
    /// big bilinear stretch looks like Lanczos". Only refines when the crop fits the fixed canvas (deep
    /// zoom — exactly when the residual stretch would be worst); re-encodes only on a new frame or moved
    /// geometry, so static playback costs one encode per video frame and holds are free.
    private func refinedCrop(of frame: CVPixelBuffer, geometry geo: UpscaleGeometry) -> (buffer: CVPixelBuffer, cropNorm: CGRect)? {
        guard !cropUpscalerFailed else { return nil }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        guard fw > 0, fh > 0 else { return nil }
        if cropUpscaler == nil {
            // Fixed canvas ≈ 0.625× of the pass-1 output (2560×1440 → 1600×896): covers zoom ≳1.6×,
            // textures stay modest. /8-aligned; orientation follows the source automatically.
            let cw = max(256, (fw * 5 / 8) & ~7)
            let ch = max(256, (fh * 5 / 8) & ~7)
            cropUpscaler = MetalFXCropUpscaler(canvasWidth: cw, canvasHeight: ch,
                                               device: renderView.metalDevice,
                                               queue: renderView.sharedQueue)
            if cropUpscaler == nil { cropUpscalerFailed = true; return nil }
        }
        guard let refiner = cropUpscaler else { return nil }
        let cropPx = CGRect(x: geo.videoCrop.minX * CGFloat(fw), y: geo.videoCrop.minY * CGFloat(fh),
                            width: geo.videoCrop.width * CGFloat(fw), height: geo.videoCrop.height * CGFloat(fh))
        // Shallow zoom → crop exceeds the canvas → pass-1 + sharpen is already close to display density.
        guard cropPx.width <= CGFloat(refiner.canvasWidth), cropPx.height <= CGFloat(refiner.canvasHeight) else {
            return nil
        }
        let stale = pass2Buffer == nil || pass2FrameStamp != frameStamp
            || pass2Geometry.map { !Self.approxEqual($0, geo) } ?? true
        if stale {
            guard let result = refiner.refine(frame: frame, cropPx: cropPx) else { return nil }
            pass2Buffer = result.buffer
            pass2Content = result.content
            pass2Geometry = geo
            pass2FrameStamp = frameStamp
        }
        guard let buffer = pass2Buffer else { return nil }
        let ow = CGFloat(refiner.outWidth), oh = CGFloat(refiner.outHeight)
        let cropNorm = CGRect(x: pass2Content.minX / ow, y: pass2Content.minY / oh,
                              width: pass2Content.width / ow, height: pass2Content.height / oh)
        return (buffer, cropNorm)
    }

    // MARK: Pause-to-enhance

    /// One-shot neural 2× of the visible crop's NATIVE pixels (no pre-scaling — the model gets the real
    /// data, unlike the dead live-path design). Crops bigger than the model's ~960×960 input cap are
    /// **tiled** through one session and composited, so the enhance works at ANY zoom past the overlay
    /// threshold (previously it silently skipped below ~1.34× — the "works sometimes" complaint). Runs on
    /// the VT queue; the result replaces the MetalFX crop until the geometry moves or playback resumes.
    private func launchStillEnhance(geometry geo: UpscaleGeometry, raw: CVPixelBuffer) {
        stillTriedGeometry = geo
        let fw = CVPixelBufferGetWidth(raw), fh = CVPixelBufferGetHeight(raw)
        guard fw > 0, fh > 0 else { return }
        let cropPx = CGRect(x: geo.videoCrop.minX * CGFloat(fw), y: geo.videoCrop.minY * CGFloat(fh),
                            width: geo.videoCrop.width * CGFloat(fw), height: geo.videoCrop.height * CGFloat(fh))
        let cw = Int(cropPx.width.rounded()), ch = Int(cropPx.height.rounded())
        guard cw >= 64, ch >= 64 else { return }

        // Tile grid: equal-size tiles, each ≤960 on both sides, /8-aligned, ≤2×2 (enough for a 1080p crop).
        let nx = (cw + 959) / 960, ny = (ch + 959) / 960
        guard nx <= 2, ny <= 2 else { return }
        let tw = min(960, min(cw, ((cw + nx - 1) / nx + 7) & ~7))
        let th = min(960, min(ch, ((ch + ny - 1) / ny + 7) & ~7))
        var tiles: [CGRect] = []   // source-pixel rects, top-left origin, clamped inside the crop
        for iy in 0..<ny {
            for ix in 0..<nx {
                let x = min(cropPx.minX + CGFloat(ix * tw), cropPx.minX + CGFloat(cw - tw))
                let y = min(cropPx.minY + CGFloat(iy * th), cropPx.minY + CGFloat(ch - th))
                tiles.append(CGRect(x: x, y: y, width: CGFloat(tw), height: CGFloat(th)))
            }
        }

        let scaler = SuperResolutionScaler(width: tw, height: th)
        let input = UpscaleBox((raw, cropPx, tiles))
        stillTask = Task.detached { [weak self, scaler, input] in
            let t0 = Date()
            let (raw, cropPx, tiles) = input.value
            var outputs: [CVPixelBuffer] = []
            for (i, tile) in tiles.enumerated() {
                guard let out = await scaler.upscale(raw, cropRect: tile,
                                                     pts: CMTime(value: CMTimeValue(i), timescale: 30)) else {
                    scaler.invalidate()
                    await self?.stillCompleted(UpscaleBox<CVPixelBuffer?>(nil), ms: 0)
                    return
                }
                outputs.append(out)
            }
            scaler.invalidate()

            let final: CVPixelBuffer?
            if outputs.count == 1 {
                final = outputs[0]
            } else {
                // Composite the scaled tiles into one buffer. The scale comes from the ACTUAL output dims
                // (the factor is queried, not assumed); overlapping edge tiles just overwrite — the model
                // is local enough that seams don't show.
                let s = CGFloat(CVPixelBufferGetWidth(outputs[0])) / tiles[0].width
                let compW = Int((cropPx.width * s).rounded()), compH = Int((cropPx.height * s).rounded())
                var dest: CVPixelBuffer?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
                CVPixelBufferCreate(kCFAllocatorDefault, compW, compH, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &dest)
                if let dest {
                    var composite: CIImage?
                    for (i, out) in outputs.enumerated() {
                        let dx = (tiles[i].minX - cropPx.minX) * s
                        let dyTop = (tiles[i].minY - cropPx.minY) * s
                        let tileOutH = CGFloat(CVPixelBufferGetHeight(out))
                        // CI origin is bottom-left; tile tops are measured from the crop's top.
                        let image = CIImage(cvPixelBuffer: out).transformed(by: CGAffineTransform(
                            translationX: dx, y: CGFloat(compH) - dyTop - tileOutH))
                        composite = composite.map { image.composited(over: $0) } ?? image
                    }
                    if let composite {
                        let context = CIContext(options: [.cacheIntermediates: false])
                        context.render(composite, to: dest)
                    }
                }
                final = dest
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            await self?.stillCompleted(UpscaleBox(final), ms: ms)
        }
    }

    private func stillCompleted(_ box: UpscaleBox<CVPixelBuffer?>, ms: Double) {
        stillTask = nil
        guard let out = box.value else { return }   // model declined — MetalFX crop stays, no state change
        // Adopt only if the user hasn't moved since the shot was taken (step() re-checks per tick too).
        guard let tried = stillTriedGeometry, let live = lastGeometry, Self.approxEqual(tried, live) else { return }
        stillBuffer = out
        stillGeometry = tried
        telemetry.mode = "Neural 2× (still)"
        telemetry.lastMs = ms
        onTelemetry(telemetry)
        // A soft tick marks the enhanced still landing (camera-focus-style "locked on" cue).
        Haptics.selectionTick()
    }

    private func dropStill() {
        guard stillBuffer != nil || stillGeometry != nil else { return }
        stillBuffer = nil
        stillGeometry = nil
        if telemetry.mode != "MetalFX 2×", upscaler != nil {
            telemetry.mode = "MetalFX 2×"
            onTelemetry(telemetry)
        }
    }

    /// Geometry equality loose enough to ignore float jitter, tight enough that any real pan/zoom differs.
    private static func approxEqual(_ a: UpscaleGeometry, _ b: UpscaleGeometry) -> Bool {
        func close(_ x: CGFloat, _ y: CGFloat, _ eps: CGFloat) -> Bool { abs(x - y) < eps }
        return close(a.videoCrop.minX, b.videoCrop.minX, 0.004)
            && close(a.videoCrop.minY, b.videoCrop.minY, 0.004)
            && close(a.videoCrop.width, b.videoCrop.width, 0.004)
            && close(a.videoCrop.height, b.videoCrop.height, 0.004)
            && close(a.placement.minX, b.placement.minX, 1.5)
            && close(a.placement.minY, b.placement.minY, 1.5)
            && close(a.placement.width, b.placement.width, 1.5)
            && close(a.placement.height, b.placement.height, 1.5)
    }

    /// Full-frame upscale a newly-decoded frame (rebuilding the fixed-size scaler only if the DECODED
    /// size changed — a quality switch — never on zoom/pan).
    private func ingest(_ buffer: CVPixelBuffer) {
        lastRawBuffer = buffer
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return }

        frameStamp &+= 1
        if let up = upscaler, up.inputWidth != w || up.inputHeight != h {
            upscaler = nil
            upscalerFailed = false
            cropUpscaler = nil
            cropUpscalerFailed = false
            pass2Buffer = nil
            pass2Geometry = nil
        }
        if upscaler == nil, !upscalerFailed {
            // Gates: >1080p-class sources don't need help (and 2× output would be huge); HDR is out of
            // scope (MetalFX perceptual mode expects SDR/sRGB).
            guard w <= 1920, h <= 1920, min(w, h) <= 1100 else {
                upscalerFailed = true
                markSkip("source >1080p-class"); return
            }
            let attach = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
            let transfer = (attach[kCVImageBufferTransferFunctionKey as String] as? String) ?? "?"
            let primaries = (attach[kCVImageBufferColorPrimariesKey as String] as? String) ?? "?"
            if transfer.contains("2084") || transfer.uppercased().contains("HLG") || primaries.contains("2020") {
                upscalerFailed = true
                markSkip("HDR/wide-gamut"); return
            }
            upscaler = MetalFXFrameUpscaler(inputWidth: w, inputHeight: h,
                                            device: renderView.metalDevice,
                                            queue: renderView.sharedQueue)
            if let up = upscaler {
                telemetry.inSize = "\(w)×\(h)"
                telemetry.outSize = "\(up.outputWidth)×\(up.outputHeight)"
                telemetry.mode = "MetalFX 2×"
                telemetry.skipReason = ""
                onTelemetry(telemetry)
                RemoteLog.shared.event("⚙︎ upscale-mfx", [("in", "\(w)×\(h)"), ("out", "\(up.outputWidth)×\(up.outputHeight)")])
            } else {
                upscalerFailed = true
                telemetry.supported = false
                markSkip("MetalFX unavailable")
                RemoteLog.shared.event("⚙︎ upscale-fail", [("where", "metalfx-init"), ("in", "\(w)×\(h)")])
                return
            }
        }
        guard let upscaler else { return }

        let t0 = CACurrentMediaTime()
        if let out = upscaler.upscale(buffer) {
            latestUpscaled = out
            telemetry.frames += 1
            telemetry.lastMs = (CACurrentMediaTime() - t0) * 1000   // encode cost; GPU completes async
            onTelemetry(telemetry)
        }
    }

    private func setPresenting(_ now: Bool, reason: String) {
        if renderView.isHidden == now { renderView.isHidden = !now }
        guard telemetry.presenting != now || telemetry.skipReason != reason else { return }
        telemetry.presenting = now
        telemetry.skipReason = reason
        onTelemetry(telemetry)
    }

    private func markSkip(_ reason: String) {
        renderView.isHidden = true
        if telemetry.presenting { telemetry.presenting = false }
        guard telemetry.skipReason != reason else { return }
        telemetry.skipReason = reason
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
