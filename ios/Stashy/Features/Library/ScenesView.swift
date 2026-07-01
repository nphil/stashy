import SwiftUI
import AVFoundation

@Observable
@MainActor
final class ScenesViewModel {
    var scenes: [StashScene] = []
    var query = SceneQuery()
    var isLoading = false
    var errorMessage: String?
    private var hasMore = true
    private var currentPage = 1
    let pageSize = 25

    func loadFirstPage(client: StashClient) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        currentPage = 1
        scenes = []
        hasMore = true
        await fetchPage(client: client)
        isLoading = false
    }

    func loadNextPageIfNeeded(triggerID: String, client: StashClient) async {
        guard hasMore, !isLoading,
              scenes.suffix(pageSize / 2).contains(where: { $0.id == triggerID })
        else { return }
        isLoading = true
        currentPage += 1
        await fetchPage(client: client)
        isLoading = false
    }

    private func fetchPage(client: StashClient) async {
        do {
            let result = try await client.findScenes(query, page: currentPage, perPage: pageSize)
            // Dedupe: paginated pages can overlap and return scenes already in the list.
            // Duplicate ids confuse ForEach identity, mis-routing taps to the wrong card.
            let existing = Set(scenes.map(\.id))
            let newScenes = result.scenes.filter { !existing.contains($0.id) }
            scenes.append(contentsOf: newScenes)
            hasMore = scenes.count < result.count && !newScenes.isEmpty
        } catch {
            if currentPage > 1 { currentPage -= 1 }
            errorMessage = error.localizedDescription
        }
    }
}

struct ScenesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router
    @State private var viewModel = ScenesViewModel()
    @State private var path: [Route] = []
    @State private var previewPresenter = ScenePreviewPresenter()
    @State private var filterExpanded = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var filterActive: Bool {
        !viewModel.query.tags.isEmpty || viewModel.query.sort != .date || viewModel.query.direction != .desc
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.current.backgroundColor.ignoresSafeArea())
                // Filter panel floats over the immersive list.
                .overlay(alignment: .top) {
                    if filterExpanded {
                        SceneFilterPanel(query: $viewModel.query)
                            .padding(.top, 4)
                            .transition(.scale(scale: 0.05, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
                .navigationTitle("Scenes")
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
        .environment(\.scenePreviewPresenter, previewPresenter)
        .overlay { ScenePreviewOverlay(presenter: previewPresenter, onOpen: { path.append(.scene($0)) }) }
        .onChange(of: viewModel.query) { _, _ in
            guard let client = appState.client else { return }
            Task { await viewModel.loadFirstPage(client: client) }
        }
        // A tag tapped elsewhere filters scenes to just that tag (pops to the grid).
        .onChange(of: router.sceneTagFilter) { _, tag in
            guard let tag else { return }
            path = []
            viewModel.query = SceneQuery(tags: [tag])
            router.sceneTagFilter = nil
        }
        .task {
            guard let client = appState.client else { return }
            Task { await TagRankingStore.shared.refreshIfNeeded(client: client) }
            guard viewModel.scenes.isEmpty else { return }
            await viewModel.loadFirstPage(client: client)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.scenes.isEmpty && viewModel.isLoading {
            ProgressView("Loading scenes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.scenes.isEmpty && !viewModel.isLoading {
            if let err = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Scenes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Retry") {
                        guard let client = appState.client else { return }
                        Task { await viewModel.loadFirstPage(client: client) }
                    }
                }
            } else if !viewModel.query.tags.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "tag.slash",
                    description: Text("No scenes match the selected tags.")
                )
            } else {
                ContentUnavailableView(
                    "No Scenes",
                    systemImage: "film.stack",
                    description: Text("Your Stash library is empty.")
                )
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(viewModel.scenes) { scene in
                        SceneGridCell(
                            scene: scene,
                            apiKey: appState.client?.apiKey ?? "",
                            onOpen: { path.append(.scene($0)) }
                        ) {
                            guard let client = appState.client else { return }
                            Task {
                                await viewModel.loadNextPageIfNeeded(
                                    triggerID: scene.id,
                                    client: client
                                )
                            }
                            prefetchThumbnails(around: scene)
                        }
                    }
                }
                .padding(12)

                if viewModel.isLoading {
                    ProgressView()
                        .padding()
                }
            }
            .refreshable {
                guard let client = appState.client else { return }
                await viewModel.loadFirstPage(client: client)
            }
        }
    }

    private func prefetchThumbnails(around scene: StashScene) {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }),
              let apiKey = appState.client?.apiKey else { return }
        let start = min(idx + 1, viewModel.scenes.count - 1)
        let end = min(idx + viewModel.pageSize, viewModel.scenes.count)
        guard start < end else { return }
        let urls = viewModel.scenes[start..<end].compactMap { $0.thumbnailURL(apiKey: apiKey) }
        Task.detached(priority: .background) {
            await imageCache.prefetch(urls: urls)
        }
    }
}

// MARK: - Scene card

struct SceneCard: View {
    let scene: StashScene
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LibraryEdits.self) private var edits
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var thumbnail: UIImage?

    /// Rating on a 0–5 scale, reading through the edits store so a rating set on the detail screen
    /// shows here immediately.
    private var ratingStars: Double? {
        guard let r = edits.rating(for: scene) else { return nil }
        return Double(r) / 20.0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail layer: a fixed 16:9 frame the image fills + crops into (no distortion).
            Rectangle()
                .fill(themeManager.current.surfaceColor)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: blurThumbnails ? 28 : 0)
                    } else {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(themeManager.current.foregroundColor.opacity(0.25))
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .topTrailing) {
                    if let dur = scene.formattedDuration() {
                        Text(dur)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let stars = ratingStars, stars > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").font(.system(size: 8))
                            Text(String(format: "%.1f", stars)).font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                    }
                }
                .clipped()

            Text(scene.title ?? "Untitled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .blur(radius: blurTitles ? 5 : 0)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            thumbnail = try? await imageCache.image(for: url)
        }
    }
}

// MARK: - Player layer

/// A thin `AVPlayerLayer`-backed view that fills + crops without playback controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        // Clear so any view layered underneath (e.g. a poster thumbnail) shows until the
        // first decoded frame arrives, avoiding a black flash.
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.backgroundColor = UIColor.clear.cgColor
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
