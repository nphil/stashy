import SwiftUI

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
    /// Render the ellipsis vertically (⋮) by rotating the always-valid `ellipsis` symbol. There is no
    /// `ellipsis.vertical` SF Symbol, so naming it renders nothing — an invisible-but-tappable button.
    var vertical = false
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
                .rotationEffect(.degrees(vertical ? 90 : 0))
                .font(.title3.weight(.semibold))
                .foregroundStyle(themeManager.current.foregroundColor)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
    }
}
