import SwiftUI
import MetalKit
import AVFoundation
import CoreImage

/// A live, frame-matched blurred backdrop for the inline AVPlayer. A display link pulls the current
/// decoded frame from the player's `AVPlayerItemVideoOutput`, downscales it, Gaussian-blurs it on the
/// GPU, and draws it aspect-fill behind the sharp video — so it tracks and blends with what's playing
/// at no extra decode cost (hardware decode is untouched; we only blur a small copy of the frame that's
/// already in memory). It pauses itself whenever it leaves the window (e.g. in fullscreen).
@MainActor
final class LiveBlurBackdropView: UIView, MTKViewDelegate {
    private let mtkView: MTKView
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private weak var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var currentImage: CIImage?

    /// Heavy blur on a 1/4-res copy: cheap, and the downscale + radius hide any granularity.
    private let downscale: CGFloat = 0.25
    private let blurRadius: Double = 18

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device)
        mtkView = MTKView(frame: .zero, device: device)
        super.init(frame: frame)

        backgroundColor = .black
        mtkView.framebufferOnly = false           // CIContext renders into the drawable texture
        mtkView.isPaused = true                    // driven manually from the display link
        mtkView.enableSetNeedsDisplay = false
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.delegate = self
        mtkView.isOpaque = true
        addSubview(mtkView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(output: AVPlayerItemVideoOutput) {
        self.output = output
        // Route through a weak proxy so the run-loop-retained display link doesn't retain (leak) us.
        let proxy = DisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        proxy.link = link
        link.preferredFramesPerSecond = 20        // the backdrop doesn't need full framerate
        link.add(to: .main, forMode: .common)
        link.isPaused = (window == nil)
        displayLink = link
    }

    // Stop pulling frames whenever we're not on screen (fullscreen swaps us out for plain black).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.isPaused = (window == nil)
    }

    fileprivate func step() {
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        let source = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
        // Clamp before blurring so the edges stay opaque instead of fading to transparent.
        currentImage = source
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: source.extent)
        mtkView.draw()
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let target = view.drawableSize
        guard target.width > 0, target.height > 0 else { return }

        // Aspect-fill the (blurred) frame into the drawable so it covers the whole backdrop.
        let extent = image.extent
        let scale = max(target.width / extent.width, target.height / extent.height)
        let tx = (target.width - extent.width * scale) / 2 - extent.minX * scale
        let ty = (target.height - extent.height * scale) / 2 - extent.minY * scale
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty)))

        ciContext.render(
            scaled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

/// Weak-target proxy for the backdrop's `CADisplayLink`. The run loop retains the link, and the link
/// retains its target — so targeting the view directly would leak it. The proxy holds the view weakly
/// and invalidates the link once the view is gone.
private final class DisplayLinkProxy: NSObject {
    weak var target: LiveBlurBackdropView?
    var link: CADisplayLink?

    init(target: LiveBlurBackdropView) {
        self.target = target
        super.init()
    }

    @objc func tick() {
        guard let target else {
            link?.invalidate()
            link = nil
            return
        }
        // The display link fires on the main run loop, so the view's main-actor state is safe here.
        MainActor.assumeIsolated { target.step() }
    }
}

/// Hosts an engine-owned backdrop `UIView` (the live blur) behind the zoom surface, full-bleed.
struct PlayerBackdropHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}
