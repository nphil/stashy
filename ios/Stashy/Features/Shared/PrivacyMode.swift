import SwiftUI
import UIKit

/// "Privacy Mode" — one toggle (`@AppStorage("privacyMode")`) that blurs ALL media across the app:
/// thumbnails, performer images, titles/filenames, scrub sprites, and video (inline + fullscreen).
/// Static imagery uses a cheap SwiftUI `.blur`; live/peekable media uses a hardware-cheap
/// `UIVisualEffectView` overlay and a press-and-hold peek.
enum Privacy {
    static let key = "privacyMode"
    /// Blur strength, tunable from Settings → Privacy. Media is only as private as the weakest blur in
    /// the app, so ONE value drives every site rather than per-call-site constants that drift apart.
    static let radiusKey = "privacyBlurRadius"
    static let defaultImageRadius: Double = 28   // strong enough that a thumbnail isn't discernible
    static let minImageRadius: Double = 12
    static let maxImageRadius: Double = 60

    /// Read straight from `UserDefaults`, NOT through a per-view `@AppStorage`. This is consulted by a
    /// modifier that sits on every grid thumbnail and title, and an `@AppStorage` there would register a
    /// defaults observer per visible cell — a standing scroll-perf cost for a number that only ever
    /// changes from one Settings slider. Nothing needs live invalidation: `privacyMode` IS observed (so
    /// toggling the mode redraws everything), and Settings covers the grid while the slider moves.
    static var imageRadius: CGFloat {
        let stored = UserDefaults.standard.double(forKey: radiusKey)
        return CGFloat(stored > 0 ? stored : defaultImageRadius)
    }
    /// Text needs far less blur than imagery to become unreadable, and derives from the same slider so
    /// names and thumbnails can never end up at mismatched strengths.
    static var titleRadius: CGFloat { max(4, imageRadius / 4) }

    /// For the non-View callers. Blurring is a `ViewModifier` concern, but Privacy Mode also has to
    /// gate what leaves the app entirely — the Live Activity title is rendered by the system on the
    /// Lock Screen, where no modifier of ours can reach it. Read directly, same reasoning as
    /// `imageRadius`.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

private struct PrivacyBlurModifier: ViewModifier {
    enum Kind { case image, title }
    let kind: Kind
    @AppStorage(Privacy.key) private var privacyMode = false

    @ViewBuilder func body(content: Content) -> some View {
        // Structural on/off, NOT `.blur(radius: 0)`: a zero-radius blur still inserts a Gaussian filter
        // node per view, and this modifier sits on EVERY grid thumbnail and title — hundreds of no-op
        // filter layers during scrolling. With privacy off the content now renders filter-free; the
        // identity change on toggle is irrelevant (flipping Privacy Mode is a rare Settings action).
        if privacyMode {
            content.blur(radius: kind == .image ? Privacy.imageRadius : Privacy.titleRadius)
        } else {
            content
        }
    }
}

extension View {
    /// Blur an image/thumbnail when Privacy Mode is on. Apply this at EVERY site that renders a frame,
    /// a poster, a performer photo or a scraped image — the mode is worthless if one surface leaks.
    func privacyImageBlur() -> some View { modifier(PrivacyBlurModifier(kind: .image)) }
    /// Blur a title/name/filename when Privacy Mode is on.
    func privacyTitleBlur() -> some View { modifier(PrivacyBlurModifier(kind: .title)) }
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
