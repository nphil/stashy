import SwiftUI

/// Funnel toggle button for the nav bar. It only flips `expanded` — the panel is presented from a stable
/// sibling of the list content (`LibraryDropdownPanel`), NOT from this toolbar item, because a panel hosted
/// on a toolbar item is torn down and re-presented whenever the toolbar rebuilds (which happens on every
/// query change, since `isActive` changes) — the pop-down/pop-up flicker.
struct FilterFunnelButton: View {
    @Binding var expanded: Bool
    var isActive: Bool
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isActive ? themeManager.current.accentColor : themeManager.current.foregroundColor)
        }
    }
}

extension View {
    /// Dismiss an open dropdown when the user scrolls OR taps the list behind it. Applied to the list content
    /// so a swipe both scrolls the list AND closes the panel in one seamless gesture. While open, the
    /// high-priority tap consumes the first tap instead of allowing the same tap to dismiss the panel AND
    /// activate a scene/performer underneath it. No-ops while the panel is closed. Works for scenes +
    /// performers.
    func dismissesPopover(_ isPresented: Binding<Bool>) -> some View {
        modifier(PopoverDismissalModifier(isPresented: isPresented))
    }
}

private struct PopoverDismissalModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                guard isPresented, phase != .idle else { return }
                // The grid is already moving. Remove the glass in this same transaction instead of
                // animating it for another 280 ms while it re-samples every scrolling frame.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isPresented = false
                }
            }
            // Higher priority than a card's tap gesture: an outside tap dismisses ONLY. A drag still fails
            // this TapGesture and proceeds into the ScrollView, preserving swipe-to-dismiss-and-scroll.
            .highPriorityGesture(TapGesture().onEnded {
                isPresented = false
            }, including: isPresented ? GestureMask.all : GestureMask.none)
    }
}

/// Sort + inline tag filter panel. Themed, semi-transparent; floats over the list so the content
/// scrolls behind it. Editing updates the bound query in real time.
struct SceneFilterPanel: View {
    @Binding var query: SceneQuery
    // Folded-in ⋯ actions (Scenes only; Performers passes none). Rendered as buttons at the bottom of the
    // panel so the old ellipsis menu could be removed from the toolbar.
    var onDownloadAll: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var bulkLoading = false
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState

    var body: some View {
        // Popover content: no floating panel chrome (the system popover is the container); just the
        // sort row + custom tag chips, sized to a comfortable popover width.
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sort").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                sortMenu
            }
            HStack {
                Text("Show").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                downloadedToggle
            }
            // Only shown once the plugin's served report is loaded (reading the store here makes the row
            // appear reactively after the refresh below). Libraries without the plugin never see it.
            // Resolution / Frame rate / Quality are available BOTH as sorts (Sort menu above) and as filters
            // here — filter to a subset, then sort within it.
            if PlayabilityStore.shared.isAvailable {
                HStack {
                    Text("Playability").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    playabilityMenu
                }
                HStack {
                    Text("Resolution").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    reportMenu($query.resolution, icon: "rectangle.on.rectangle",
                               active: query.resolution != .any) { $0.label }
                }
                HStack {
                    Text("Frame rate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    reportMenu($query.fps, icon: "speedometer", active: query.fps != .any) { $0.label }
                }
                HStack {
                    Text("Quality").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    reportMenu($query.quality, icon: "sparkles", active: query.quality != .any) { $0.label }
                }
            }
            Divider().opacity(0.25)
            InlineTagEditor(selected: $query.tags)

            // Folded-in actions (the old ⋯ menu). Solid rows — never glass over the glass panel.
            if onDownloadAll != nil || onSelect != nil {
                Divider().opacity(0.25)
                if let onDownloadAll {
                    actionRow("Download all in filter", icon: "arrow.down.circle", loading: bulkLoading, action: onDownloadAll)
                        .disabled(bulkLoading)
                }
                if let onSelect {
                    actionRow("Select…", icon: "checkmark.circle", action: onSelect)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
        .task {
            if let client = appState.client {
                await PlayabilityStore.shared.refresh(serverURL: client.serverURL, apiKey: client.apiKey)
            }
        }
    }

    private func actionRow(_ title: String, icon: String, loading: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: icon) }
                }
                .frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(themeManager.current.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(themeManager.current.foregroundColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A themed capsule menu for a report-backed filter enum (resolution / fps / quality). Mirrors the
    /// playability menu's look; `active` highlights it in the accent colour when a non-Any value is chosen.
    private func reportMenu<T: CaseIterable & Identifiable & Equatable>(
        _ selection: Binding<T>, icon: String, active: Bool, label: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        Menu {
            ForEach(Array(T.allCases)) { opt in
                Button { selection.wrappedValue = opt } label: {
                    Label(label(opt), systemImage: selection.wrappedValue == opt ? "checkmark" : icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label(selection.wrappedValue))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .filterPill(active: active,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
        }
    }

    private var playabilityMenu: some View {
        Menu {
            ForEach(Playability.allCases) { p in
                Button { query.playability = p } label: {
                    Label(p.label, systemImage: query.playability == p ? "checkmark" : Self.symbol(p))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "iphone").font(.caption)
                Text(query.playability.label)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .filterPill(active: query.playability != .any,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
        }
    }

    private static func symbol(_ p: Playability) -> String {
        switch p {
        case .any: return "square.grid.2x2"
        case .directPlay: return "bolt.fill"
        case .needsRemux: return "shippingbox"
        case .needsTranscode: return "arrow.triangle.2.circlepath"
        }
    }

    private var downloadedToggle: some View {
        Button {
            query.downloadedOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: query.downloadedOnly ? "arrow.down.circle.fill" : "square.grid.2x2").font(.caption)
                Text(query.downloadedOnly ? "Downloaded" : "All videos")
            }
            .filterPill(active: query.downloadedOnly,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
        }
        .buttonStyle(.plain)
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
            .filterPill(active: false,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
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
                .capsuleField(foreground: themeManager.current.foregroundColor)

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
            .filterPill(active: false,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
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
            .filterPill(active: query.favoritesOnly,
                        tint: .pink,
                        foreground: themeManager.current.foregroundColor)
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
            .filterPill(active: query.ethnicity != nil,
                        tint: themeManager.current.accentColor,
                        foreground: themeManager.current.foregroundColor)
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
        // Populate from the synchronous ranking cache on the first frame. Waiting for `.task` to assign
        // the same tags one frame later resized the glass sheet immediately after it appeared, which read
        // as a flash on both library screens.
        let shownResults = results.isEmpty && search.trimmingCharacters(in: .whitespaces).isEmpty
            ? TagRankingStore.shared.popularTags
            : results

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
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            // Solid inside the panel's glass: nested glass layers add a sampler per chip.
                            .background(themeManager.current.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Search tags…", text: $search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .capsuleField(foreground: themeManager.current.foregroundColor)

            // Suggestions with favourited tags floated to the front. Each chip has a heart (toggles the
            // tag's favorite) and a tap area (adds it to the filter) — adjacent buttons, not nested.
            let unselected = shownResults.filter { !selected.contains($0) }
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
                        // Keep one glass surface (the sheet), not up to sixteen nested glass surfaces.
                        .background(
                            edits.isFavorite(tag)
                                ? Color.pink.opacity(0.28)
                                : themeManager.current.foregroundColor.opacity(0.12),
                            in: Capsule()
                        )
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
