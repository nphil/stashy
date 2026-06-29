import SwiftUI
import UIKit

/// Full-screen image viewer with Apple Photos-style zooming: pinch to a focal point with bounce,
/// free inertial panning when zoomed, double-tap to zoom into the tapped point (and back), and a
/// quick swipe-down to dismiss. Used for the tappable performer portrait.
struct FullScreenImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            ZoomableImageScroll(image: image, onSwipeDownDismiss: { dismiss() })
                .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
        }
        .statusBarHidden(true)
    }
}

/// `UIScrollView` hosting a `UIImageView` so the image gets native pinch/pan/zoom with bounce.
struct ZoomableImageScroll: UIViewRepresentable {
    let image: UIImage
    let onSwipeDownDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let coordinator = context.coordinator
        let scroll = UIScrollView()
        scroll.delegate = coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.decelerationRate = .fast
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let swipe = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipe.delegate = coordinator
        scroll.addGestureRecognizer(swipe)

        coordinator.scrollView = scroll
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layout()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageScroll
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        init(_ parent: ZoomableImageScroll) { self.parent = parent }

        func layout() {
            guard let scroll = scrollView, scroll.zoomScale == 1 else { return }
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
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
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scroll.zoom(to: rect, animated: true)
            }
        }

        @objc func handleSwipe(_ gr: UIPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
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
