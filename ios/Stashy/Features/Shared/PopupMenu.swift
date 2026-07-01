import SwiftUI

/// Shared reveal used by the app's custom popovers (filter panels + the scene/performer action menu)
/// so they animate identically. The scale anchor is the button corner the popover hangs from, so it
/// visibly grows *out of* the button; `.geometryGroup()` at the call site keeps the scale smooth (it
/// stops SwiftUI from re-laying-out the popover's children on every frame of the animation, which is
/// what previously read as a low-frame-rate expansion).
enum PopoverReveal {
    static let animation: Animation = .spring(response: 0.30, dampingFraction: 0.76)

    static func transition(_ anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.2, anchor: anchor).combined(with: .opacity)
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
