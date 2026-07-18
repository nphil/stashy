import SwiftUI

extension View {
    /// Styles a filter/sort control inside the glass filter panel as a pill. When `active`, the whole pill
    /// fills with `tint` (the theme accent, or pink for favorites) and its content flips to white so a set
    /// filter visibly *pops* at a glance; otherwise it's a neutral translucent capsule. These chips are
    /// deliberately SOLID, never glass — glass-on-glass (over the panel's own `.glassEffect`) reads flat
    /// (the v1.0.262 miss). Apply to the `Menu`/`Button` label content (the icon+text `HStack`); it replaces
    /// the per-site `.font`/`.foregroundStyle`/`.padding`/`.background` chain these chips used to repeat.
    func filterPill(active: Bool, tint: Color, foreground: Color) -> some View {
        self
            .font(.subheadline.weight(.medium))
            .foregroundStyle(active ? Color.white : foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? tint : foreground.opacity(0.12), in: Capsule())
    }

    /// The neutral translucent capsule behind an inline text field in a filter panel — the same fill as an
    /// inactive `filterPill`, factored out so the panel's search / name fields share one definition.
    func capsuleField(foreground: Color) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(foreground.opacity(0.12), in: Capsule())
    }
}
