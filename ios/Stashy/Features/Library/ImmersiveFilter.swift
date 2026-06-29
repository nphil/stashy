import SwiftUI

/// Glass funnel button used to reveal a filter panel over an immersive (scroll-behind) list.
struct FilterFunnelButton: View {
    @Binding var expanded: Bool
    var isActive: Bool
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isActive ? Color.white : themeManager.current.foregroundColor)
                .frame(width: 34, height: 34)
                .glassEffect(
                    isActive ? .regular.tint(themeManager.current.accentColor) : .regular,
                    in: Circle()
                )
        }
    }
}

/// Sort + inline tag filter panel. Themed, semi-transparent; floats over the list so the content
/// scrolls behind it. Editing updates the bound query in real time.
struct SceneFilterPanel: View {
    @Binding var query: SceneQuery
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sort").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                sortMenu
            }
            Divider().opacity(0.25)
            InlineTagEditor(selected: $query.tags)
        }
        .padding(14)
        .background(themeManager.current.surfaceColor.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        .padding(.horizontal, 12)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $query.sort) {
                ForEach(SceneSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(sort)
                }
            }
            Picker("Order", selection: $query.direction) {
                Label("Ascending", systemImage: "arrow.up").tag(SortDirection.asc)
                Label("Descending", systemImage: "arrow.down").tag(SortDirection.desc)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: query.sort.symbol).font(.caption)
                Text(query.sort.label)
                Image(systemName: query.direction == .asc ? "arrow.up" : "arrow.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(themeManager.current.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(themeManager.current.backgroundColor.opacity(0.6), in: Capsule())
        }
    }
}

/// Inline, live tag picker: selected chips + a search field with suggestions (popular by default).
struct InlineTagEditor: View {
    @Binding var selected: [Tag]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var search = ""
    @State private var results: [Tag] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tags", systemImage: "tag").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            if !selected.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selected) { tag in
                        Button { remove(tag) } label: {
                            HStack(spacing: 4) {
                                Text(tag.name)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular.tint(themeManager.current.accentColor), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Search tags…", text: $search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(themeManager.current.backgroundColor.opacity(0.6), in: Capsule())

            let suggestions = results.filter { !selected.contains($0) }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions.prefix(14)) { tag in
                        Button { add(tag) } label: {
                            Text(tag.name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await load("") }
        .onChange(of: search) { _, q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                await load(q)
            }
        }
    }

    private func load(_ q: String) async {
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            let popular = TagRankingStore.shared.popularTags
            if !popular.isEmpty { results = popular; return }
        }
        guard let client = appState.client else { return }
        results = (try? await client.findTags(query: q)) ?? []
    }

    private func add(_ tag: Tag) {
        if !selected.contains(tag) {
            selected.append(tag)
            TagRankingStore.shared.recordSelection([tag])
        }
        search = ""
    }

    private func remove(_ tag: Tag) {
        selected.removeAll { $0 == tag }
    }
}
