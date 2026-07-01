import SwiftUI

/// Funnel button that presents its filter panel as a **native popover** anchored to the button — real
/// iOS present/dismiss physics, and it floats above all content so it can't be clipped. The panel's
/// custom chips live inside; the container is the system popover material.
struct FilterFunnelButton<Panel: View>: View {
    @Binding var expanded: Bool
    var isActive: Bool
    @ViewBuilder var panel: () -> Panel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits

    var body: some View {
        Button {
            expanded.toggle()   // the popover animates itself
        } label: {
            // No background — just themed lines, kept legible over content with a soft shadow.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isActive ? themeManager.current.accentColor : themeManager.current.foregroundColor)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .frame(width: 34, height: 34)
        }
        .popover(isPresented: $expanded) {
            panel()
                // Re-inject the observables the panel/tag editor rely on — presented content doesn't
                // always inherit them, and a missing one is a hard crash.
                .environment(themeManager)
                .environment(appState)
                .environment(edits)
                .presentationCompactAdaptation(.popover)   // stay a popover on iPhone, not a sheet
        }
    }
}

/// Sort + inline tag filter panel. Themed, semi-transparent; floats over the list so the content
/// scrolls behind it. Editing updates the bound query in real time.
struct SceneFilterPanel: View {
    @Binding var query: SceneQuery
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        // Popover content: no floating panel chrome (the system popover is the container); just the
        // sort row + custom tag chips, sized to a comfortable popover width.
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sort").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                sortMenu
            }
            Divider().opacity(0.25)
            InlineTagEditor(selected: $query.tags)
        }
        .padding(16)
        .frame(width: 330)
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

/// Performer filter panel: name search, sort, ethnicity, and inline tags — mirrors the scenes
/// panel and updates the list in real time.
struct PerformerFilterPanel: View {
    @Binding var query: PerformerQuery
    @Environment(ThemeManager.self) private var themeManager
    @State private var name = ""
    @State private var nameTask: Task<Void, Never>?

    private let ethnicities = ["Caucasian", "Black", "Asian", "Latin", "Indian", "Middle Eastern", "Mixed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Performer name…", text: $name)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(themeManager.current.backgroundColor.opacity(0.6), in: Capsule())

            HStack {
                Text("Sort").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                sortMenu
            }
            HStack {
                Text("Ethnicity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                ethnicityMenu
            }
            HStack {
                Text("Favorites").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                favoritesToggle
            }
            Divider().opacity(0.25)
            InlineTagEditor(selected: $query.tags)
        }
        .padding(16)
        .frame(width: 330)
        .onAppear { name = query.search }
        .onChange(of: name) { _, value in
            nameTask?.cancel()
            nameTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                query.search = value
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $query.sort) {
                ForEach(PerformerSort.allCases) { sort in
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

    private var favoritesToggle: some View {
        Button {
            query.favoritesOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: query.favoritesOnly ? "heart.fill" : "heart").font(.caption)
                Text(query.favoritesOnly ? "Favorites only" : "All")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(query.favoritesOnly ? .pink : themeManager.current.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(themeManager.current.backgroundColor.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var ethnicityMenu: some View {
        Menu {
            Picker("Ethnicity", selection: Binding(
                get: { query.ethnicity ?? "" },
                set: { query.ethnicity = $0.isEmpty ? nil : $0 }
            )) {
                Text("Any").tag("")
                ForEach(ethnicities, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.caption)
                Text(query.ethnicity ?? "Any")
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
    @Environment(LibraryEdits.self) private var edits
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

            // Suggestions with favourited tags floated to the front. Each chip has a heart (toggles the
            // tag's favorite) and a tap area (adds it to the filter) — adjacent buttons, not nested.
            let unselected = results.filter { !selected.contains($0) }
            let suggestions = unselected.filter { edits.isFavorite($0) } + unselected.filter { !edits.isFavorite($0) }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions.prefix(16)) { tag in
                        HStack(spacing: 5) {
                            FavoriteHeart(isFavorite: edits.isFavorite(tag), size: 11, offColor: .secondary) { newValue in
                                edits.setTagFavorite(newValue, id: tag.id, client: appState.client)
                            }
                            Button { add(tag) } label: {
                                Text(tag.name).font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(edits.isFavorite(tag) ? .regular.tint(.pink.opacity(0.5)) : .regular, in: Capsule())
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
