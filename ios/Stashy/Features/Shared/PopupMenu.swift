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

/// A sleek popup menu that expands out of its own trigger button — the app's custom alternative to the
/// native context menu, matching the filter panels' look and (now) their animation. Tapping the button
/// toggles it; tapping an item runs it and closes.
struct PopupMenu: View {
    var systemImage = "ellipsis"
    let actions: [PopupMenuAction]
    @Environment(ThemeManager.self) private var themeManager
    @State private var open = false

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(PopoverReveal.animation) { open.toggle() }
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(themeManager.current.foregroundColor)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if open {
                menu
                    .geometryGroup()
                    .transition(PopoverReveal.transition(.topTrailing))
                    .offset(y: 38)   // hang just below the button, right edges aligned
                    .zIndex(1)
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider().opacity(0.12) }
                Button {
                    withAnimation(PopoverReveal.animation) { open = false }
                    action.action()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.systemImage).font(.subheadline).frame(width: 20)
                        Text(action.title).font(.subheadline.weight(.medium))
                        Spacer(minLength: 16)
                    }
                    .foregroundStyle(action.isDestructive ? Color.red : themeManager.current.foregroundColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
        .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
    }
}
