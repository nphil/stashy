import SwiftUI

/// The library top-bar search: a glass **magnifier** that expands into a glass **text field** on tap. This
/// re-creates the old `.searchToolbarBehavior(.minimize)` feel as a *custom* control, because the nav bar
/// (which hosted `.searchable`) is now hidden in favour of the custom glass top-bar overlay.
///
/// Mounted as a full-screen sibling of the list content (like `GlassMorphDropdown`), so it floats over the
/// grid and survives the list's reload branch-flips:
///  • **collapsed** → a magnifier button pinned top-trailing, inset left of the filter funnel; it tints to
///    the accent colour while a search is active so a collapsed-but-filtered state stays visible;
///  • **expanded** → a field spanning the bar, with a dim tap-catcher behind it that both blocks
///    pass-through to the grid and collapses the field on an outside tap.
struct LibrarySearchField: View {
    @Binding var text: String
    @Binding var expanded: Bool
    var prompt: String
    /// Trailing inset when collapsed, so the magnifier sits just left of the filter funnel (34pt funnel +
    /// 12pt bar inset + 8pt gap).
    var collapsedTrailingInset: CGFloat = 54
    @Environment(ThemeManager.self) private var themeManager
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: expanded ? .top : .topTrailing) {
            if expanded {
                // Full-screen catcher: blocks pass-through to the grid AND collapses on an outside tap.
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { expanded = false }
                    .transition(.opacity)
                field
                    .padding(.top, 6)
                    .padding(.horizontal, 12)
            } else {
                magnifier
                    .padding(.top, 6)
                    .padding(.trailing, collapsedTrailingInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .top : .topTrailing)
        .animation(.snappy(duration: 0.3), value: expanded)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .foregroundStyle(themeManager.current.foregroundColor)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        // Autofocus after the field mounts (a tiny delay lets the field settle before focus is requested,
        // otherwise the keyboard occasionally no-shows on the first expand).
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    private var magnifier: some View {
        Button { expanded = true } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(text.isEmpty ? themeManager.current.foregroundColor
                                              : themeManager.current.accentColor)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
    }
}
