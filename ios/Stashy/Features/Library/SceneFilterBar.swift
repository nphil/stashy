import SwiftUI

/// Horizontal row of filter/sort chips for a scene list. Sorting uses a native `Menu` with inline
/// `Picker`s (standard checkmarks); tag filtering opens a searchable picker sheet.
struct SceneFilterBar: View {
    @Binding var query: SceneQuery
    var showTagFilter = true

    @Environment(ThemeManager.self) private var themeManager
    @State private var showTagPicker = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sortMenu
                if showTagFilter { tagChip }
                if !query.tags.isEmpty {
                    Button {
                        query.tags = []
                    } label: {
                        chip(icon: "xmark", text: "Clear", active: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(selected: $query.tags)
        }
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
            chip(
                icon: query.sort.symbol,
                text: query.sort.label,
                trailing: query.direction == .asc ? "arrow.up" : "arrow.down",
                active: false
            )
        }
    }

    private var tagChip: some View {
        Button {
            showTagPicker = true
        } label: {
            chip(
                icon: "tag",
                text: query.tags.isEmpty ? "Tags" : "\(query.tags.count) Tag\(query.tags.count == 1 ? "" : "s")",
                active: !query.tags.isEmpty
            )
        }
        .buttonStyle(.plain)
    }

    private func chip(icon: String, text: String, trailing: String? = nil, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text)
            if let trailing {
                Image(systemName: trailing).font(.caption2)
            }
        }
        // Solid filter pill (accent-filled when active) — shared with the immersive filter panel so every
        // filter chip in the app reads the same.
        .filterPill(active: active,
                    tint: themeManager.current.accentColor,
                    foreground: themeManager.current.foregroundColor)
    }
}

/// Searchable, multi-select tag picker backed by live `findTags` lookups from Stash.
struct TagPickerSheet: View {
    @Binding var selected: [Tag]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [Tag] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !selected.isEmpty {
                        sectionHeader("Selected")
                        FlowLayout(spacing: 8) {
                            ForEach(selected) { tag in tagChip(tag, isSelected: true) { remove(tag) } }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let available = results.filter { !selected.contains($0) }
                    sectionHeader(searchText.isEmpty ? "Popular tags" : "Results")
                    if available.isEmpty {
                        Text("No tags found").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(available) { tag in tagChip(tag, isSelected: false) { add(tag) } }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .scrollEdgeFade()
            .navigationTitle("Filter by Tags")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !selected.isEmpty { Button("Clear") { selected = [] } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let client = appState.client {
                    await TagRankingStore.shared.refreshIfNeeded(client: client)
                }
                await runSearch("")
            }
            .onChange(of: searchText) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await runSearch(q)
                }
            }
        }
        // Compact half-sheet with selectable chips (not a full-screen list) — cleaner + smaller, and
        // avoids the popover-teardown landmine that a dropdown anchored in the scrolling filter bar hits.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func tagChip(_ tag: Tag, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(tag.name)
                Image(systemName: isSelected ? "xmark.circle.fill" : "plus")
                    .font(.caption2)
                    .opacity(isSelected ? 1 : 0.55)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : themeManager.current.foregroundColor)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isSelected ? themeManager.current.accentColor : themeManager.current.surfaceColor, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func runSearch(_ q: String) async {
        // Empty query → show cached popular/most-used tags instead of querying every time.
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
    }

    private func remove(_ tag: Tag) {
        selected.removeAll { $0 == tag }
    }
}
