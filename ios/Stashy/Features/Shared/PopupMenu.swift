import SwiftUI

/// Shared reveal used by the app's custom popovers (filter panels + the scene/performer action menu).
///
/// It deliberately does **not** scale the popover's content. Scaling a view full of `.glassEffect`
/// (Liquid Glass) forces the backdrop blur to re-render at every intermediate size on the main thread —
/// which is exactly what made the old `.scale(0.2 → 1)` reveal look low-frame-rate. Native menus dodge
/// this by animating a rasterized platter on the render server; we approximate that by rendering the
/// content once at full size (blur computed a single time) and revealing it with a cheap **clip mask
/// that unfolds from the button corner**, plus a fade. A growing rectangle mask is trivial for the GPU,
/// so the glass never re-blurs and the expand still reads as coming out of the button.
enum PopoverReveal {
    static let animation: Animation = .spring(response: 0.32, dampingFraction: 0.82)

    static func transition(_ anchor: UnitPoint) -> AnyTransition {
        .modifier(
            active: ClipRevealModifier(progress: 0, anchor: anchor),
            identity: ClipRevealModifier(progress: 1, anchor: anchor)
        )
    }
}

/// Reveals content by growing a rectangular mask from `anchor` (mostly vertically, like a dropdown
/// unfurling) and fading in — without transforming the content itself, so blurred/glass content isn't
/// re-rendered mid-animation.
struct ClipRevealModifier: ViewModifier {
    let progress: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(Double(min(1, progress * 1.5)))
            .mask {
                Rectangle().scaleEffect(x: 0.6 + 0.4 * progress, y: progress, anchor: anchor)
            }
    }
}

struct PopupMenuAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void
}

/// The scene/performer action menu. Uses the **native** SwiftUI `Menu`: the system renders it above all
/// app content in its own context, so it can't be clipped by a card and gets the real iOS present/
/// dismiss physics — which a custom overlay can't fully match. The items here are plain text actions,
/// so we lose nothing to native styling (custom chips/backgrounds aren't possible in a native menu, but
/// those live in the filter panels, which stay custom). Destructive actions render red via the button role.
struct PopupMenu: View {
    var systemImage = "ellipsis"
    let actions: [PopupMenuAction]
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Menu {
            ForEach(actions) { action in
                Button(role: action.isDestructive ? .destructive : nil, action: action.action) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(themeManager.current.foregroundColor)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
    }
}
