import SwiftUI

/// A floating Liquid-Glass dropdown for the library top bar — the jobs panel (anchored top-leading, under
/// the title button) and the filter panel (top-trailing, under the funnel). It is a **stable sibling of the
/// list content** in the screen's `ZStack`, so it survives `content`'s branch flips during reloads (the
/// `FilterPopoverAnchor` landmine), and it exists **only while presented** so glass never samples the
/// scrolling grid per-frame (the 120 Hz scroll-perf rule — the panel shows only while the list is static,
/// and `dismissesPopover` closes it the instant a scroll begins).
///
/// Two things it gets right that the earlier attempts didn't:
///  • **native open/close animation** — the system's own snappy spring + a scale-from-the-anchor transition,
///    matching iOS menu/popover physics (no custom glass-morph that "pops"); and
///  • **no tap-through** — a full-frame hit-catcher *behind* the panel's controls absorbs taps that land in
///    the gaps between chips, so they never fall through to a scene card (the "tap a tag, hit the scene
///    behind it" bug). Controls sit in front of the catcher, so their taps still register.
///
/// It deliberately has **no dimming backdrop over the list**: dismissal is driven by `dismissesPopover` on
/// the content, so a swipe both scrolls the list AND closes the panel in one seamless motion (full scroll
/// performance, no modal pause).
struct LibraryDropdownPanel<Panel: View>: View {
    @Binding var isPresented: Bool
    /// `.topLeading` (jobs, under the title) or `.topTrailing` (filter, under the funnel).
    var anchor: Alignment = .topTrailing
    @ViewBuilder var panel: () -> Panel

    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits

    private var unitAnchor: UnitPoint { anchor == .topLeading ? .topLeading : .topTrailing }

    var body: some View {
        ZStack(alignment: anchor) {
            if isPresented {
                panel()
                    // Re-inject the observables the panel/tag editor read (harmless if already inherited).
                    .environment(themeManager)
                    .environment(appState)
                    .environment(edits)
                    // Full-frame hit-catcher BEHIND the controls: absorbs taps in the gaps so they never
                    // reach a scene card behind the panel; controls in front still receive their taps.
                    .background(
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { }
                    )
                    // Floating glass sheet — glass shows character here over the vibrant grid/mesh. Only ever
                    // drawn while the list is STATIC (any scroll dismisses it), so there's no per-frame
                    // re-sample cost.
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(anchor == .topLeading ? .leading : .trailing, 10)
                    .padding(.top, 6)
                    // Emerge from the anchor corner with the system's own spring — native menu/popover physics.
                    .transition(.scale(scale: 0.9, anchor: unitAnchor).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
        .animation(.snappy(duration: 0.28, extraBounce: 0.03), value: isPresented)
    }
}
