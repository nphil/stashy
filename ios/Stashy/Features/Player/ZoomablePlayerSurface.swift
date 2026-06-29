import SwiftUI
import UIKit

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

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let scroll = UIScrollView()
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
        coordinator.layoutContainer()
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.attachPlayerView()
        scroll.maximumZoomScale = zoomEnabled ? 4 : 1
        if !coordinator.isScrubbing { scroll.isScrollEnabled = zoomEnabled }
        if !zoomEnabled, scroll.zoomScale != 1 {
            scroll.setZoomScale(1, animated: false)
        }
        coordinator.layoutContainer()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomablePlayerSurface
        let container = UIView()
        weak var scrollView: UIScrollView?
        private(set) var isScrubbing = false
        private let haptic = UIImpactFeedbackGenerator(style: .medium)
        private var scrubStartX: CGFloat = 0
        private var scrubAnchorTime: TimeInterval = 0

        init(_ parent: ZoomablePlayerSurface) { self.parent = parent }

        /// Re-parent the KSPlayer view into the zoomable container exactly once (it may appear late).
        func attachPlayerView() {
            guard let playerView = parent.model.layer.player.view else { return }
            playerView.backgroundColor = .clear
            if playerView.superview !== container {
                playerView.removeFromSuperview()
                container.addSubview(playerView)
            }
            playerView.frame = container.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        /// At rest (zoom == 1) the container fills the scroll view; UIScrollView scales it from there.
        func layoutContainer() {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale == 1 {
                container.frame = CGRect(origin: .zero, size: scroll.bounds.size)
                scroll.contentSize = scroll.bounds.size
                parent.model.layer.player.view?.frame = container.bounds
            }
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Keep the content centred while it's smaller than the viewport (Photos behaviour).
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: 0, right: 0)
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
