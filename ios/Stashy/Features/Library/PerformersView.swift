import SwiftUI

struct PerformersView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var loader = PaginatedLoader<Performer>(pageSize: 30)
    @State private var query = PerformerQuery()
    // Custom top-bar search (nav bar hidden) — glass magnifier that expands into a field. Debounced below.
    @State private var searchText = ""
    @State private var searchExpanded = false
    @State private var filterExpanded = false
    // The jobs status dropdown (title button, top-leading). Mutually exclusive with the filter dropdown.
    @State private var jobsExpanded = false
    @State private var path: [Route] = []
    @State private var reloadDebounce: Task<Void, Never>?
    // Shared namespace for the zoom transition from a performer cell into the performer detail.
    @Namespace private var zoomNS

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    // Sort persists across launches; filters (search/ethnicity/tags/favorites) always start cleared.
    init() {
        var q = PerformerQuery()
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "sort.performers.field"), let s = PerformerSort(rawValue: raw) { q.sort = s }
        if let raw = d.string(forKey: "sort.performers.dir"), let dir = SortDirection(rawValue: raw) { q.direction = dir }
        _query = State(initialValue: q)
    }

    private var filterActive: Bool {
        !query.search.isEmpty || query.ethnicity != nil
            || !query.tags.isEmpty || query.favoritesOnly
            || query.sort != .name || query.direction != .asc
    }

    /// Reload the first page for the current query.
    private func reload() async {
        guard let client = appState.client else { return }
        let q = query
        await loader.reload { page, perPage in
            let result = try await client.findPerformers(q, page: page, perPage: perPage)
            return (result.performers, result.count)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Reserve space so the grid starts below the floating glass bar.
                    .safeAreaInset(edge: .top) { Color.clear.frame(height: 50) }
                // Custom glass top bar (jobs dropdown / search / filter) — a stable ZStack sibling of the
                // churning `content`; the dropdowns' own dim backdrop catches taps (no `dismissesPopover`).
                topChrome
            }
            // Only one dropdown / the search field open at a time.
            .onChange(of: filterExpanded) { _, open in if open { jobsExpanded = false } }
            .onChange(of: jobsExpanded) { _, open in if open { filterExpanded = false } }
            .onChange(of: searchExpanded) { _, open in if open { jobsExpanded = false; filterExpanded = false } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            // Briefly lock scrolling right after a zoom-back so the iOS 26 source-card freeze is never seen.
            .zoomReturnScrollGate(depth: path.count)
            // The nav bar is replaced by the custom glass top bar; hide it (pushed detail keeps its own).
            .toolbar(.hidden, for: .navigationBar)
            .task(id: searchText) {
                guard searchText != query.search else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                query.search = searchText
            }
            .navigationDestination(for: Route.self) { route in
                // Pair the zoom with the grid cell's matchedTransitionSource for performer detail; a scene
                // opened from within a performer page uses the default push.
                if case .performer(let performer) = route {
                    RouteDestination(route: route, path: $path)
                        .navigationTransition(.zoom(sourceID: performer.id, in: zoomNS))
                } else {
                    RouteDestination(route: route, path: $path)
                }
            }
        }
        // Debounced: rapid filter changes (e.g. tapping the favorites toggle repeatedly) coalesce into
        // one reload instead of firing an overlapping storm of loads under the open popover.
        .onChange(of: query) { _, _ in
            reloadDebounce?.cancel()
            reloadDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .onChange(of: query.sort) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "sort.performers.field") }
        .onChange(of: query.direction) { _, dir in UserDefaults.standard.set(dir.rawValue, forKey: "sort.performers.dir") }
        .task {
            guard loader.items.isEmpty else { return }
            await reload()
        }
        .onDisappear { reloadDebounce?.cancel() }
        .libraryEditErrorToast(edits)
    }

    // MARK: - Custom glass top bar (replaces the nav bar)

    /// Jobs dropdown (top-left, status only — no action buttons on Performers), search, and the filter
    /// dropdown (top-right). Same custom overlay as Scenes; see the note there.
    @ViewBuilder
    private var topChrome: some View {
        ZStack(alignment: .top) {
            if !searchExpanded {
                GlassMorphDropdown(expanded: $jobsExpanded, anchor: .topLeading) {
                    morphTitleButton
                } panel: {
                    JobsPanel(showActions: false)
                }
                GlassMorphDropdown(expanded: $filterExpanded, anchor: .topTrailing) {
                    funnelLabel
                } panel: {
                    PerformerFilterPanel(query: $query)
                }
            }
            LibrarySearchField(text: $searchText, expanded: $searchExpanded, prompt: "Search performers")
        }
    }

    /// The glass title button (top-left) that morphs into the jobs panel.
    private var morphTitleButton: some View {
        HStack(spacing: 6) {
            Text("Performers").font(.title3.weight(.semibold))
            Image(systemName: "chevron.down").font(.caption.weight(.bold))
        }
        .foregroundStyle(themeManager.current.foregroundColor)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    /// The filter-funnel label (top-right), tinted when a filter is active.
    private var funnelLabel: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.title3.weight(.semibold))
            .foregroundStyle(filterActive ? themeManager.current.accentColor : themeManager.current.foregroundColor)
            .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var content: some View {
        if loader.items.isEmpty && loader.isLoading {
            ProgressView("Loading performers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loader.items.isEmpty {
            ContentUnavailableView(
                filterActive ? "No Matches" : "No Performers",
                systemImage: "person.2",
                description: Text(filterActive ? "No performers match these filters." : "Your Stash has no performers.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(edits.visible(loader.items)) { performer in
                        // Heart is overlaid *outside* the NavigationLink so its tap never conflicts with
                        // (or double-fires alongside) navigation. Anchored top-trailing over the portrait.
                        NavigationLink(value: Route.performer(performer)) {
                            PerformerCard(performer: performer, apiKey: appState.client?.apiKey ?? "")
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            HStack {
                                Spacer()
                                FavoriteHeart(isFavorite: edits.isFavorite(performer), size: 15) { newValue in
                                    edits.setPerformerFavorite(newValue, id: performer.id, client: appState.client)
                                }
                            }
                            .padding(8)
                        }
                        .onAppear {
                            Task { await loader.loadNextIfNeeded(triggerID: performer.id) }
                        }
                        // Source for the zoom into the performer detail (Apple-Photos style).
                        .matchedTransitionSource(id: performer.id, in: zoomNS)
                    }
                }
                .padding(12)

                if loader.isLoading {
                    ProgressView().padding()
                }
            }
        }
    }
}

struct PerformerRow: View {
    let performer: Performer
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @State private var avatar: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = avatar {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .privacyImageBlur()
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            Text(performer.name)
                .font(.body)
        }
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            avatar = try? await imageCache.image(for: url, priority: true)
        }
    }
}
