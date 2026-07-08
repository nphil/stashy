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
            // At rest: the content (and the player view inside it) exactly fills the viewport. Re-pin on
            // every pass — not just when the content size changed — so a stale frame left over from the
            // portrait→landscape rotation (which would leave the video taller than the viewport, clipping
            // the bottom controls and the part you can't pan to) always snaps back to the current bounds.
            let target = CGRect(origin: .zero, size: size)
            if contentView.frame != target { contentView.frame = target }
            if contentSize != size { contentSize = size }
            if let inner = contentView.subviews.first, inner.frame != target { inner.frame = target }
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

/// Hosts the video render surface inside a `UIScrollView` so the fullscreen video gets
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
    /// True while AI slow-mo is engaged. Its interpolated-frame render view is hosted **inside** this zoom
    /// container (a sibling above the player view) so pinch/pan zoom transforms it identically to the video.
    /// Kept as a single source of truth (the scroll view) rather than mirroring the transform onto a separate
    /// overlay, which would desync from the live gesture.
    var slowMoActive: Bool
    @Binding var zoomScale: CGFloat
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    let onSingleTap: () -> Void
    let onScrubStart: () -> Void
    let onScrubEnd: () -> Void
    let onSwipeDownDismiss: () -> Void
    /// Sprite preview-frame (cue) index for a time — the hold-scrub fires one haptic tick each time it
    /// changes, matching the scrub bar's feel (fast drag → flurry of taps, slow → one per frame).
    var cueIndex: (TimeInterval) -> Int = { _ in -1 }

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
        coordinator.syncSlowMoView()
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.attachPlayerView()
        coordinator.syncSlowMoView()
        scroll.maximumZoomScale = zoomEnabled ? 4 : 1
        if !coordinator.isScrubbing { scroll.isScrollEnabled = zoomEnabled }
        // Defensive: UIScrollView's built-in pinch recogniser can be left disabled by isScrollEnabled
        // toggles (an interrupted hold-scrub, an engine swap mid-gesture) and then never zooms again.
        // Re-assert it on every update — a no-op when already correct, so zero cost. The AI slow-mo /
        // upscale overlay is hosted INSIDE this zoom container, so pinch transforms it identically and
        // is entirely independent of that pipeline.
        scroll.pinchGestureRecognizer?.isEnabled = zoomEnabled
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
        /// The slow-mo render view currently hosted in `container` (tracked separately from
        /// `model.slowMoRenderView`, which is niled on stop — so we can still remove the frozen overlay).
        weak var hostedSlowView: UIView?
        /// Tracks the last zoom-enabled state so updateUIView only forces a relayout on the toggle.
        var lastZoomEnabled: Bool?
        private(set) var isScrubbing = false
        private let haptic = UIImpactFeedbackGenerator(style: .medium)
        private var scrubStartX: CGFloat = 0
        private var scrubAnchorTime: TimeInterval = 0
        private var lastCueIndex = -1

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

        /// Host (or remove) the AI slow-mo render view inside the zoom container so it shares the scroll
        /// view's zoom/pan transform (pinch, double-tap, inertial pan all "just work"). It sits above the
        /// player view; removing it on stop reveals the live `AVPlayerLayer` again. Non-interactive so it
        /// never intercepts the scroll view's gestures.
        func syncSlowMoView() {
            let wanted = parent.slowMoActive ? parent.model.slowMoRenderView : nil
            if hostedSlowView !== wanted {
                hostedSlowView?.removeFromSuperview()
                hostedSlowView = nil
            }
            guard let slow = wanted else { return }
            if slow.superview !== container {
                slow.removeFromSuperview()
                slow.frame = container.bounds
                slow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                slow.isUserInteractionEnabled = false
                container.addSubview(slow)
            }
            container.bringSubviewToFront(slow)
            hostedSlowView = slow
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
                Haptics.prepareSelection()
                lastCueIndex = -1
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
                // One haptic tick each time the scrub crosses into a new preview frame.
                let idx = parent.cueIndex(parent.scrubTime)
                if idx != lastCueIndex {
                    lastCueIndex = idx
                    if idx >= 0 { Haptics.selectionTick() }
                }
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
