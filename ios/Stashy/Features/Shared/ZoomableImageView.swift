import SwiftUI
import UIKit

/// Full-screen image viewer with Apple Photos-style physics: pinch to zoom with bounce, inertial
/// panning when zoomed, double-tap to zoom into the tapped point (and back), and an interactive
/// drag-to-dismiss where the image tracks your finger, scales down, and the backdrop fades — releasing
/// past a threshold (or with a downward flick) dismisses, otherwise it springs back. Used for the
/// tappable performer portrait.
struct FullScreenImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    /// 0 = at rest, 1 = fully dragged away. Drives the backdrop fade so the dismiss reads like Photos.
    @State private var dragProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(Double(1 - min(1, dragProgress))).ignoresSafeArea()

            ZoomableImageScroll(
                image: image,
                onDragProgress: { dragProgress = $0 },
                onDismiss: { dismiss() }
            )
            .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .opacity(dragProgress > 0.01 ? 0 : 1)   // hide the chrome while dragging away
            .padding(.leading, 16)
            .padding(.top, 12)
        }
        .statusBarHidden(true)
    }
}

/// `UIScrollView` hosting a `UIImageView` for native pinch/pan/zoom with bounce + inertia, plus an
/// interactive drag-to-dismiss gesture that only engages when not zoomed.
struct ZoomableImageScroll: UIViewRepresentable {
    let image: UIImage
    var onDragProgress: (CGFloat) -> Void = { _ in }
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let c = context.coordinator
        let scroll = CenteringScrollView()
        scroll.imageViewRef = c.imageView
        scroll.delegate = c
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.decelerationRate = .fast
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        c.scrollView = scroll

        c.imageView.image = image
        c.imageView.contentMode = .scaleAspectFit
        c.imageView.isUserInteractionEnabled = true
        scroll.addSubview(c.imageView)

        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let dismissPan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = c
        scroll.addGestureRecognizer(dismissPan)
        c.dismissPan = dismissPan

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
    }

    /// Sizes the image view to the scroll view's real bounds in `layoutSubviews` (not at make/update
    /// time, when bounds are still zero — that was why the image never appeared) and keeps the content
    /// centered as it zooms.
    final class CenteringScrollView: UIScrollView {
        weak var imageViewRef: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let iv = imageViewRef else { return }
            if zoomScale == minimumZoomScale {
                iv.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
            let b = bounds.size, content = contentSize
            let insetX = max((b.width - content.width) / 2, 0)
            let insetY = max((b.height - content.height) / 2, 0)
            contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: 0, right: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageScroll
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        weak var dismissPan: UIPanGestureRecognizer?

        init(_ parent: ZoomableImageScroll) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let b = scrollView.bounds.size, content = scrollView.contentSize
            let insetX = max((b.width - content.width) / 2, 0)
            let insetY = max((b.height - content.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: 0, right: 0)
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gr.location(in: imageView)
                let newScale = min(2.5, scroll.maximumZoomScale)
                let w = scroll.bounds.width / newScale
                let h = scroll.bounds.height / newScale
                scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
            }
        }

        @objc func handleDismissPan(_ gr: UIPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
            let t = gr.translation(in: scroll)
            switch gr.state {
            case .changed:
                let progress = max(0, t.y) / max(scroll.bounds.height, 1)
                let scale = max(0.6, 1 - progress)
                imageView.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: scale, y: scale)
                parent.onDragProgress(min(1, progress * 1.6))
            case .ended, .cancelled:
                let v = gr.velocity(in: scroll)
                let commit = gr.state == .ended && t.y > 0 && (t.y > 120 || v.y > 900)
                if commit {
                    parent.onDragProgress(1)
                    parent.onDismiss()
                } else {
                    parent.onDragProgress(0)
                    UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) {
                        self.imageView.transform = .identity
                    }
                }
            default:
                break
            }
        }

        // Engage drag-to-dismiss only when not zoomed and the drag is predominantly downward; let it run
        // alongside the scroll view's own pan (which is inert at min zoom since content fits the screen).
        func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
            guard gr === dismissPan, let pan = gr as? UIPanGestureRecognizer, let scroll = scrollView else { return true }
            guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
            let v = pan.velocity(in: scroll)
            return v.y > 0 && abs(v.y) > abs(v.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
