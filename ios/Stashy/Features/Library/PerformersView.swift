import SwiftUI

@Observable
@MainActor
final class PerformersViewModel {
    var performers: [Performer] = []
    var query = PerformerQuery()
    var isLoading = false
    var errorMessage: String?
    private var hasMore = true
    private var currentPage = 1
    private let pageSize = 30

    func loadFirstPage(client: StashClient) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        currentPage = 1
        performers = []
        hasMore = true
        await fetchPage(client: client)
        isLoading = false
    }

    func loadNextPageIfNeeded(triggerID: String, client: StashClient) async {
        guard hasMore, !isLoading,
              performers.suffix(pageSize / 2).contains(where: { $0.id == triggerID })
        else { return }
        isLoading = true
        currentPage += 1
        await fetchPage(client: client)
        isLoading = false
    }

    private func fetchPage(client: StashClient) async {
        do {
            let result = try await client.findPerformers(query, page: currentPage, perPage: pageSize)
            let existing = Set(performers.map(\.id))
            let newPerformers = result.performers.filter { !existing.contains($0.id) }
            performers.append(contentsOf: newPerformers)
            hasMore = performers.count < result.count && !newPerformers.isEmpty
        } catch {
            if currentPage > 1 { currentPage -= 1 }
            errorMessage = error.localizedDescription
        }
    }
}

struct PerformersView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var viewModel = PerformersViewModel()
    @State private var filterExpanded = false
    @State private var path: [Route] = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    private var filterActive: Bool {
        !viewModel.query.search.isEmpty || viewModel.query.ethnicity != nil
            || !viewModel.query.tags.isEmpty || viewModel.query.sort != .name || viewModel.query.direction != .asc
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.current.backgroundColor.ignoresSafeArea())
                .overlay(alignment: .top) {
                    if filterExpanded {
                        PerformerFilterPanel(query: $viewModel.query)
                            .padding(.top, 4)
                            .transition(.scale(scale: 0.05, anchor: .topTrailing).combined(with: .opacity))
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
        .onChange(of: viewModel.query) { _, _ in
            guard let client = appState.client else { return }
            Task { await viewModel.loadFirstPage(client: client) }
        }
        .task {
            guard viewModel.performers.isEmpty, let client = appState.client else { return }
            await viewModel.loadFirstPage(client: client)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.performers.isEmpty && viewModel.isLoading {
            ProgressView("Loading performers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.performers.isEmpty {
            ContentUnavailableView(
                filterActive ? "No Matches" : "No Performers",
                systemImage: "person.2",
                description: Text(filterActive ? "No performers match these filters." : "Your Stash has no performers.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.performers) { performer in
                        NavigationLink(value: Route.performer(performer)) {
                            PerformerCard(performer: performer, apiKey: appState.client?.apiKey ?? "")
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            guard let client = appState.client else { return }
                            Task {
                                await viewModel.loadNextPageIfNeeded(
                                    triggerID: performer.id,
                                    client: client
                                )
                            }
                        }
                    }
                }
                .padding(12)

                if viewModel.isLoading {
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
