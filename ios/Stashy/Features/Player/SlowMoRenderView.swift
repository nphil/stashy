import SwiftUI
import UIKit
import MetalKit
import CoreImage

/// A minimal Metal view that draws a single decoded frame (aspect-fit), driven externally — used by the
/// AI slow-mo path to present the interpolated + real frame stream on screen while it's engaged (≤0.5×),
/// overlaying the hidden `AVPlayerLayer`. Mirrors `LiveBlurBackdropView`'s proven MTKView + CIContext setup
/// (same "render a CVPixelBuffer to the drawable" mechanics), minus the blur and its own display link:
/// `SlowMoRunner` calls `present(_:)` on each display tick with the frame due now.
@MainActor
final class SlowMoRenderView: UIView, MTKViewDelegate {
    private let mtkView: MTKView
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private var currentImage: CIImage?

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        mtkView = MTKView(frame: .zero, device: device)
        super.init(frame: frame)

        backgroundColor = .black
        mtkView.framebufferOnly = false          // CIContext renders into the drawable texture
        mtkView.isPaused = true                   // driven manually from present()
        mtkView.enableSetNeedsDisplay = false
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.delegate = self
        mtkView.isOpaque = true
        addSubview(mtkView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draw `pixelBuffer` now (aspect-fit into the view).
    func present(_ pixelBuffer: CVPixelBuffer) {
        currentImage = CIImage(cvPixelBuffer: pixelBuffer)
        mtkView.draw()
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let target = view.drawableSize
        guard target.width > 0, target.height > 0 else { return }

        // Aspect-fit the frame into the drawable (letterbox), centred — matches AVPlayerLayer .resizeAspect.
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(target.width / extent.width, target.height / extent.height)
        let tx = (target.width - extent.width * scale) / 2 - extent.minX * scale
        let ty = (target.height - extent.height * scale) / 2 - extent.minY * scale
        // Upscaling (interpolation runs at ≤720p while the screen/zoom wants more): Lanczos resampling is
        // visibly sharper than the default bilinear `transformed(by:)`, at trivial GPU cost on this class of
        // device. Downscale/1:1 keeps the plain transform. (True AI upscale — VTLowLatencySuperResolution
        // Scaler, same VTFrameProcessor family as the interpolator — is the planned follow-up feature.)
        let scaled: CIImage
        if scale > 1.001 {
            scaled = image
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0
                ])
                .transformed(by: CGAffineTransform(translationX: tx, y: ty))
        } else {
            scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
        }

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Debug-only GPU busy-time probe (Stats overlay). Gated on a bare bool so it's zero-cost when off.
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
