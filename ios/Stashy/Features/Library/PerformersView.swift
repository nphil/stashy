import SwiftUI

struct PerformersView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits
    @Environment(ThemeManager.self) private var themeManager
    @State private var loader = PaginatedLoader<Performer>(pageSize: 30)
    @State private var query = PerformerQuery()
    // Native minimized search (magnifier → field), top-right. Debounced into query.search below.
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var filterExpanded = false
    // The jobs status dropdown (title button, top-leading). Mutually exclusive with the filter dropdown.
    @State private var jobsExpanded = false
    @State private var path: [Route] = []
    @State private var reloadDebounce: Task<Void, Never>?
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
                    // Swipe/tap the list to close either dropdown AND scroll in one motion (no modal backdrop).
                    .dismissesPopover($filterExpanded)
                    .dismissesPopover($jobsExpanded)
                // Stable ZStack siblings of the churning `content`; exist only while open, so glass never
                // samples the scrolling grid per-frame. Jobs = top-leading (under the title), filter = trailing.
                LibraryDropdownPanel(isPresented: $jobsExpanded, anchor: .topLeading) {
                    JobsPanel(showActions: false)
                }
                LibraryDropdownPanel(isPresented: $filterExpanded, anchor: .topTrailing) {
                    PerformerFilterPanel(query: $query)
                }
            }
            // Only one dropdown open at a time.
            .onChange(of: filterExpanded) { _, open in if open { jobsExpanded = false } }
            .onChange(of: jobsExpanded) { _, open in if open { filterExpanded = false } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .navigationBarTitleDisplayMode(.inline)
            // Native minimized search (magnifier → field), pinned top-right; debounced below.
            .searchable(text: $searchText, isPresented: $searchPresented, prompt: "Search performers")
            .searchToolbarBehavior(.minimize)
            .task(id: searchText) {
                guard searchText != query.search else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                query.search = searchText
            }
            .toolbar {
                // Title (top-left) = the jobs dropdown button.
                ToolbarItem(placement: .topBarLeading) { titleJobsButton }
                // Search magnifier (top-right), then the funnel.
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    FilterFunnelButton(expanded: $filterExpanded, isActive: filterActive)
                }
            }
            .navigationDestination(for: Route.self) { route in
                // Native push/pop avoids iOS 26's zoom-source freeze and is immediately scrollable on return.
                RouteDestination(route: route, path: $path)
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
        .onDisappear {
            reloadDebounce?.cancel()
            setBrowseScrolling(false)
        }
        .libraryEditErrorToast(edits)
    }

    // MARK: - Top-bar

    /// The nav-bar title, as a button that drops the jobs panel down (top-leading). Lives in the SYSTEM nav
    /// bar so scrolling stays buttery and the bar collapses natively.
    private var titleJobsButton: some View {
        Button {
            jobsExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Performers").font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(jobsExpanded ? 180 : 0))
            }
            .foregroundStyle(jobsExpanded ? themeManager.current.accentColor : themeManager.current.foregroundColor)
            .animation(.snappy(duration: 0.28), value: jobsExpanded)
        }
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
                    }
                }
                .padding(12)

                if loader.isLoading {
                    ProgressView().padding()
                }
            }
            .onScrollPhaseChange { _, phase in
                setBrowseScrolling(
                    phase != .idle,
                    surface: "performers",
                    phase: String(describing: phase)
                )
            }
        }
    }

    private func setBrowseScrolling(
        _ scrolling: Bool,
        surface: String = "performers",
        phase: String = "idle"
    ) {
        BrowseScrollCoordinator.shared.setScrolling(
            scrolling, surface: surface, phase: phase
        )
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
