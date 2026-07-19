import SwiftUI

/// A glass button that **morphs** into a glass panel using iOS 26 Liquid Glass — one `GlassEffectContainer`
/// holding either the collapsed button or the expanded panel, both tagged with the SAME `glassEffectID`, so
/// SwiftUI fluidly melts one shape into the other (the seamless morph the owner wanted, not a scale/opacity
/// fake). Used for the library top-bar dropdowns (jobs status on the left, filters on the right).
///
/// A dim, **tap-catching backdrop** covers the screen while open, so:
///  • taps NEVER fall through to the grid behind it — this is what fixes the old filter panel's
///    "tap a tag chip, accidentally hit the scene behind it" bug (the old `FilterPopoverAnchor` deliberately
///    had *no* catcher, so anything outside a chip's exact rect leaked to the list); and
///  • a tap anywhere outside the panel dismisses it.
///
/// Mounted as a stable overlay sibling of the list content (NOT a toolbar item, NOT inside the churning
/// content subtree), so it survives the list's reload branch-flips — the `FilterPopoverAnchor` landmine.
struct GlassMorphDropdown<ButtonLabel: View, Panel: View>: View {
    @Binding var expanded: Bool
    /// Which top corner the button + panel anchor to (`.topLeading` for the title/jobs, `.topTrailing` for
    /// the filter funnel).
    var anchor: Alignment = .topLeading
    @ViewBuilder var buttonLabel: () -> ButtonLabel
    @ViewBuilder var panel: () -> Panel

    @Namespace private var glassNS

    var body: some View {
        ZStack(alignment: anchor) {
            if expanded {
                // Full-screen catcher: blocks pass-through to the grid AND dismisses on an outside tap.
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { expanded = false }
                    .transition(.opacity)
            }

            GlassEffectContainer(spacing: nil) {
                if expanded {
                    panel()
                        // Invisible hit-catcher filling the panel's own frame, BEHIND its controls: taps in
                        // the gaps between chips/rows are absorbed here instead of falling through to the
                        // backdrop (which would dismiss) or — the old bug — to a scene card behind the panel.
                        // Controls sit in front of this background, so their taps still reach them.
                        .background(
                            Color.black.opacity(0.0001)
                                .contentShape(Rectangle())
                                .onTapGesture { }
                        )
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .glassEffectID(Self.morphID, in: glassNS)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                } else {
                    Button { expanded = true } label: { buttonLabel() }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID(Self.morphID, in: glassNS)
                }
            }
            // Inset from the screen corner into the bar area; the container respects the safe area (no
            // ignoresSafeArea here), so the button/panel sit just below the status bar.
            .padding(.top, 6)
            .padding(.horizontal, 12)
            // The container fills the overlay and pins its single shape to `anchor`; the empty area around it
            // is transparent + non-interactive, so those taps reach the backdrop (dismiss) — never the grid.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
        .animation(.smooth(duration: 0.34), value: expanded)
    }

    // Stable per-instance morph identity (each dropdown has its own @Namespace, so ids never collide).
    private static var morphID: String { "glass-morph" }
}
