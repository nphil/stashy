import SwiftUI
import UIKit

/// Scroll view that keeps its zoomable content matched to the viewport in `layoutSubviews` — which
/// UIKit calls *after* the bounds change. Doing this here (instead of from the representable's
/// `updateUIView`, which runs *before* SwiftUI's new frame is applied) is what makes the surface
/// resize correctly across the inline↔fullscreen transition and rotation, with no stale-bounds gaps.
final class ZoomScrollView: UIScrollView {
    weak var contentView: UIView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let contentView else { return }
        let size = bounds.size
        if zoomScale <= minimumZoomScale {
            // At rest: the content (and the player view inside it) exactly fills the viewport.
            if contentView.bounds.size != size {
                contentView.frame = CGRect(origin: .zero, size: size)
                contentSize = size
                contentView.subviews.first?.frame = CGRect(origin: .zero, size: size)
            }
            if contentInset != .zero { contentInset = .zero }
        } else {
            // Centre the zoomed content when a dimension is smaller than the viewport.
            let x = max((size.width - contentSize.width) / 2, 0)
            let y = max((size.height - contentSize.height) / 2, 0)
            let inset = UIEdgeInsets(top: y, left: x, bottom: 0, right: 0)
            if contentInset != inset { contentInset = inset }
        }
    }
}

/// Hosts the KSPlayer render surface inside a `UIScrollView` so the fullscreen video gets
/// Apple Photos-style zooming: pinch to any focal point, free inertial panning with bounce,
/// double-tap to zoom into the tapped point (and back), and a quick swipe-down to dismiss.
///
/// Scrubbing is a long press + drag (with a haptic) so it never fights the pan when zoomed:
/// while scrubbing we disable the scroll pan and map horizontal travel onto the timeline.
struct ZoomablePlayerSurface: UIViewRepresentable {
    let model: ScenePlayerModel
    /// Read so SwiftUI re-runs `updateUIView` (and re-attaches the player view) once it exists.
    var isReady: Bool
    /// Zoom + swipe-to-dismiss are only enabled in fullscreen.
    var zoomEnabled: Bool
    @Binding var zoomScale: CGFloat
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    let onSingleTap: () -> Void
    let onScrubStart: () -> Void
    let onScrubEnd: () -> Void
    let onSwipeDownDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let coordinator = context.coordinator
        let scroll = ZoomScrollView()
        scroll.delegate = coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = zoomEnabled ? 4 : 1
        scroll.bouncesZoom = true
        scroll.decelerationRate = .fast
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = true
        scroll.isScrollEnabled = zoomEnabled

        coordinator.container.backgroundColor = .clear
        scroll.contentView = coordinator.container
        scroll.addSubview(coordinator.container)

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        scroll.addGestureRecognizer(longPress)

        let swipe = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipe.delegate = coordinator
        scroll.addGestureRecognizer(swipe)

        coordinator.scrollView = scroll
        coordinator.attachPlayerView()
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.attachPlayerView()
        scroll.maximumZoomScale = zoomEnabled ? 4 : 1
        if !coordinator.isScrubbing { scroll.isScrollEnabled = zoomEnabled }
        // Fully reset zoom/pan whenever zooming is disabled (e.g. leaving fullscreen) so the video
        // never returns to the inline player still zoomed or offset. The actual re-sizing happens in
        // ZoomScrollView.layoutSubviews once UIKit applies the new bounds.
        if !zoomEnabled {
            coordinator.resetZoom()
        }
        // Only force a relayout when zoom is toggled (inline↔fullscreen). Bounds changes (rotation,
        // fullscreen resize) already trigger ZoomScrollView.layoutSubviews on their own, so we must
        // not call setNeedsLayout unconditionally here — updateUIView can run often, and a forced
        // layout pass every time is what previously starved playback.
        if coordinator.lastZoomEnabled != zoomEnabled {
            coordinator.lastZoomEnabled = zoomEnabled
            scroll.setNeedsLayout()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomablePlayerSurface
        let container = UIView()
        weak var scrollView: ZoomScrollView?
        /// Tracks the last zoom-enabled state so updateUIView only forces a relayout on the toggle.
        var lastZoomEnabled: Bool?
        private(set) var isScrubbing = false
        private let haptic = UIImpactFeedbackGenerator(style: .medium)
        private var scrubStartX: CGFloat = 0
        private var scrubAnchorTime: TimeInterval = 0

        init(_ parent: ZoomablePlayerSurface) { self.parent = parent }

        /// Re-parent the engine's render view into the zoomable container exactly once (it may appear late).
        func attachPlayerView() {
            guard let playerView = parent.model.renderView else { return }
            playerView.backgroundColor = .clear
            if playerView.superview !== container {
                playerView.removeFromSuperview()
                container.addSubview(playerView)
            }
            playerView.frame = container.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        /// Reset zoom and pan offset — used when zooming is disabled. Re-centring/sizing is handled
        /// by `ZoomScrollView.layoutSubviews`, triggered by the zoom-scale change.
        func resetZoom() {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: false) }
            scroll.contentOffset = .zero
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Centring happens in ZoomScrollView.layoutSubviews; just publish the scale.
            parent.zoomScale = scrollView.zoomScale
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.zoomScale = scale
        }

        // MARK: - Gestures

        @objc func handleSingleTap(_ gr: UITapGestureRecognizer) {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard parent.zoomEnabled, let scroll = scrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gr.location(in: container)
                let newScale = min(2.5, scroll.maximumZoomScale)
                let w = scroll.bounds.width / newScale
                let h = scroll.bounds.height / newScale
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scroll.zoom(to: rect, animated: true)
            }
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard let scroll = scrollView else { return }
            let width = max(scroll.bounds.width, 1)
            switch gr.state {
            case .began:
                haptic.impactOccurred()
                isScrubbing = true
                scroll.isScrollEnabled = false // don't pan the zoomed video while scrubbing
                scrubStartX = gr.location(in: scroll).x
                scrubAnchorTime = parent.model.currentTime
                parent.isScrubbing = true
                parent.onScrubStart()
            case .changed:
                let x = gr.location(in: scroll).x
                let span = max(parent.model.duration, 1)
                let delta = Double((x - scrubStartX) / width) * span
                parent.scrubTime = max(0, min(parent.model.duration, scrubAnchorTime + delta))
            case .ended, .cancelled, .failed:
                if isScrubbing {
                    parent.model.seek(to: parent.scrubTime)
                    isScrubbing = false
                    scroll.isScrollEnabled = parent.zoomEnabled
                    parent.isScrubbing = false
                    parent.onScrubEnd()
                }
            default:
                break
            }
        }

        @objc func handleSwipe(_ gr: UIPanGestureRecognizer) {
            guard parent.zoomEnabled, let scroll = scrollView else { return }
            // Only when not zoomed: a downward fling dismisses (when zoomed, panning moves the video).
            guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return }
            if gr.state == .ended {
                let t = gr.translation(in: scroll)
                let v = gr.velocity(in: scroll)
                if t.y > 60, abs(t.y) > abs(t.x), v.y > 0 {
                    parent.onSwipeDownDismiss()
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
