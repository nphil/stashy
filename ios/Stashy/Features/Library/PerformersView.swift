import SwiftUI

struct PerformersView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits
    @Environment(\.imageCache) private var imageCache
    @State private var loader = PaginatedLoader<Performer>(pageSize: 30)
    @State private var query = PerformerQuery()
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var filterExpanded = false
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
            ZStack(alignment: .topTrailing) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dismissesPopover($filterExpanded)   // swipe/tap the list closes the panel AND scrolls
                // Filter dropdown hosted from a stable sibling of `content` (not an overlay on it) so it
                // survives `content`'s branch flips during reloads — see the detailed note in ScenesView.
                FilterPopoverAnchor(isPresented: $filterExpanded) {
                    PerformerFilterPanel(query: $query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .navigationTitle("Performers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Minimized search button (no scroll-top drawer), pinned top-left; expands into the field on tap.
                DefaultToolbarItem(kind: .search, placement: .topBarLeading)
                ToolbarItem(placement: .topBarTrailing) {
                    FilterFunnelButton(expanded: $filterExpanded, isActive: filterActive)
                }
            }
            // Search is a minimized toolbar button (no scroll-top drawer) — see ScenesView note. Debounced below.
            .searchable(text: $searchText, isPresented: $searchPresented, prompt: "Search performers")
            .searchToolbarBehavior(.minimize)
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
