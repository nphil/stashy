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
            .menuHighlightShape()
    }

    /// The neutral translucent capsule behind an inline text field in a filter panel — the same fill as an
    /// inactive `filterPill`, factored out so the panel's search / name fields share one definition.
    func capsuleField(foreground: Color) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(foreground.opacity(0.12), in: Capsule())
            .menuHighlightShape()
    }

    /// Teaches the system what shape this control is, for the highlight it draws over a `Menu` label while
    /// the menu opens and dismisses.
    ///
    /// **The bug this fixes (owner report, v1.0.370).** Picking a new value in a sort menu flashed a grey
    /// SQUARE-cornered slab over the pill for a frame or two before it settled back into a capsule. The
    /// slab is the system's own menu highlight: it's drawn from the label's `contentShape`, and a shape
    /// painted by SwiftUI's `.background(_:in:)` is invisible to it — the layer has no corner radius, so
    /// the system assumes a plain rectangle. Picking a LONGER label ("Date" → "Date Added") also resizes
    /// the label under the highlight, which is what made it obvious on that control first; it was always
    /// there on every capsule-shaped menu in the app. Declaring the capsule explicitly is the fix — no
    /// animation or layout change helps, because the artifact is not ours to animate.
    func menuHighlightShape() -> some View {
        contentShape(.contextMenuPreview, Capsule())
    }
}
