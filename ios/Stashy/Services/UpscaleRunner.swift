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

    /// Draw `cropNorm` (normalised, top-left origin) of `frame` into `placement` (view points) now.
    func present(frame: CVPixelBuffer, cropNorm: CGRect, placement: CGRect) {
        currentImage = CIImage(cvPixelBuffer: frame)
        self.cropNorm = cropNorm
        self.placement = placement
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

        let scaled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: dest.width / crop.width,
                                               y: dest.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: dest.minX, y: dest.minY))

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

    private var upscaler: MetalFXFrameUpscaler?
    private var upscalerFailed = false
    private var displayLink: CADisplayLink?
    private var latestUpscaled: CVPixelBuffer?
    private var lastRawBuffer: CVPixelBuffer?      // kept for the coming pause-to-enhance phase
    private var telemetry = UpscaleTelemetry()

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
        latestUpscaled = nil
        lastRawBuffer = nil
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
            setPresenting(false, reason: "zoom in to upscale")
            return
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

        guard let frame = latestUpscaled else { return }
        renderView.present(frame: frame, cropNorm: geo.videoCrop, placement: geo.placement)
        setPresenting(true, reason: "")
    }

    /// Full-frame upscale a newly-decoded frame (rebuilding the fixed-size scaler only if the DECODED
    /// size changed — a quality switch — never on zoom/pan).
    private func ingest(_ buffer: CVPixelBuffer) {
        lastRawBuffer = buffer
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return }

        if let up = upscaler, up.inputWidth != w || up.inputHeight != h {
            upscaler = nil
            upscalerFailed = false
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
