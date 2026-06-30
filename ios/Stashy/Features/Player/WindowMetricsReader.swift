import SwiftUI
import UIKit

/// Publishes the host window's bounds and safe-area insets — sourced from UIKit and refreshed live
/// across rotation — rather than relying on the ambient SwiftUI geometry of whatever screen presented
/// the player.
///
/// The fullscreen video player uses these so it lays out identically no matter where it was opened
/// from. A plain `NavigationStack` and a `.searchable` stack (which adds a search bar and a `List`)
/// report *different* safe-area/size context to a pushed view's `GeometryReader`; feeding that straight
/// into the fullscreen surface mis-sized it (video zoomed past the screen, controls pushed off-screen)
/// only on the search path. Reading the window directly removes that dependency.
struct WindowMetricsReader: UIViewRepresentable {
    @Binding var bounds: CGRect
    @Binding var safeArea: EdgeInsets

    func makeUIView(context: Context) -> WindowMetricsView { WindowMetricsView() }

    func updateUIView(_ uiView: WindowMetricsView, context: Context) {
        uiView.onChange = { b, i in
            let insets = EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
            // Defer out of the current layout pass so we never mutate SwiftUI state mid-update.
            DispatchQueue.main.async {
                if bounds != b { bounds = b }
                if safeArea != insets { safeArea = insets }
            }
        }
        uiView.reportIfPossible()
    }
}

/// A zero-impact probe view: it draws nothing but watches its window for bounds / safe-area changes
/// (which fire on rotation and on insertion) and reports them upward, de-duplicated.
final class WindowMetricsView: UIView {
    var onChange: ((CGRect, UIEdgeInsets) -> Void)?
    private var last: (CGRect, UIEdgeInsets)?

    override func didMoveToWindow() { super.didMoveToWindow(); reportIfPossible() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); reportIfPossible() }
    override func layoutSubviews() { super.layoutSubviews(); reportIfPossible() }

    func reportIfPossible() {
        guard let window else { return }
        let b = window.bounds
        let i = window.safeAreaInsets
        if let last, last.0 == b, last.1 == i { return }
        last = (b, i)
        onChange?(b, i)
    }
}
