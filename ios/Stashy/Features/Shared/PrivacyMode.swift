import SwiftUI
import UIKit

/// "Privacy Mode" — one toggle (`@AppStorage("privacyMode")`) that blurs ALL media across the app:
/// thumbnails, performer images, titles/filenames, scrub sprites, and video (inline + fullscreen).
/// Static imagery uses a cheap SwiftUI `.blur`; live/peekable media uses a hardware-cheap
/// `UIVisualEffectView` overlay and a press-and-hold peek.
enum Privacy {
    static let key = "privacyMode"
    static let imageRadius: CGFloat = 28   // strong enough that a thumbnail isn't discernible
    static let titleRadius: CGFloat = 7    // enough to make names/filenames unreadable
}

private struct PrivacyBlurModifier: ViewModifier {
    let radius: CGFloat
    @AppStorage(Privacy.key) private var privacyMode = false
    @ViewBuilder func body(content: Content) -> some View {
        // Structural on/off, NOT `.blur(radius: 0)`: a zero-radius blur still inserts a Gaussian filter
        // node per view, and this modifier sits on EVERY grid thumbnail and title — hundreds of no-op
        // filter layers during scrolling. With privacy off the content now renders filter-free; the
        // identity change on toggle is irrelevant (flipping Privacy Mode is a rare Settings action).
        if privacyMode {
            content.blur(radius: radius)
        } else {
            content
        }
    }
}

extension View {
    /// Blur an image/thumbnail when Privacy Mode is on.
    func privacyImageBlur() -> some View { modifier(PrivacyBlurModifier(radius: Privacy.imageRadius)) }
    /// Blur a title/name/filename when Privacy Mode is on.
    func privacyTitleBlur() -> some View { modifier(PrivacyBlurModifier(radius: Privacy.titleRadius)) }
}

/// A `UIVisualEffectView` frosted blur — blurs whatever is rendered behind it in the hierarchy, live,
/// on the GPU (no per-frame CPU cost). Used as an overlay over video/sprite content.
struct BlurEffectView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemThickMaterial
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

/// Wraps peekable media (the sprite preview player, inline/fullscreen video). In Privacy Mode it opens
/// blurred; press-and-hold reveals while the finger is held and re-blurs on release. When Privacy Mode is
/// off it's a transparent passthrough — no overlay, no gesture — so it never affects normal playback.
struct PrivacyPeek<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @AppStorage(Privacy.key) private var privacyMode = false
    @GestureState private var peeking = false

    var body: some View {
        content()
            .overlay {
                if privacyMode {
                    // The overlay stays present during a peek (faded to 0) so it keeps owning the hold
                    // gesture and the player's own gestures don't fire underneath while privacy is active.
                    BlurEffectView()
                        .opacity(peeking ? 0 : 1)
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.12)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .updating($peeking) { _, state, _ in state = true }
                        )
                        .animation(.easeOut(duration: 0.12), value: peeking)
                }
            }
    }
}
