import SwiftUI

struct PerformersView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LibraryEdits.self) private var edits
    @Environment(\.imageCache) private var imageCache
    @State private var loader = PaginatedLoader<Performer>(pageSize: 30)
    @State private var query = PerformerQuery()
    @State private var filterExpanded = false
    @State private var path: [Route] = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.current.backgroundColor.ignoresSafeArea())
                .overlay(alignment: .top) {
                    if filterExpanded {
                        PerformerFilterPanel(query: $query)
                            .geometryGroup()
                            .padding(.top, 4)
                            .transition(PopoverReveal.transition(.topTrailing))
                    }
                }
                .navigationTitle("Performers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        FilterFunnelButton(expanded: $filterExpanded, isActive: filterActive)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route, path: $path)
                }
        }
        .onChange(of: query) { _, _ in
            Task { await reload() }
        }
        .task {
            guard loader.items.isEmpty else { return }
            await reload()
        }
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
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @State private var avatar: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = avatar {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: blurThumbnails ? 18 : 0)
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
