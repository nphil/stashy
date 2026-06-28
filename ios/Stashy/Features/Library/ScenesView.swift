import SwiftUI
import AVFoundation

@Observable
@MainActor
final class ScenesViewModel {
    var scenes: [StashScene] = []
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
            let result = try await client.findScenes(page: currentPage, perPage: pageSize)
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
    @Environment(\.previewCache) private var previewCache
    @Environment(ThemeManager.self) private var themeManager
    @State private var viewModel = ScenesViewModel()
    @State private var path = NavigationPath()
    @State private var isScrolling = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
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
                                    isScrolling: $isScrolling,
                                    path: $path
                                ) {
                                    guard let client = appState.client else { return }
                                    Task {
                                        await viewModel.loadNextPageIfNeeded(
                                            triggerID: scene.id,
                                            client: client
                                        )
                                    }
                                    // Prefetch thumbnails and preview clips for the next batch.
                                    prefetchThumbnails(around: scene)
                                    prefetchPreviews(around: scene)
                                }
                            }
                        }
                        .padding(12)

                        if viewModel.isLoading {
                            ProgressView()
                                .padding()
                        }
                    }
                    .onScrollPhaseChange { _, newPhase in
                        isScrolling = newPhase != .idle
                    }
                    .refreshable {
                        guard let client = appState.client else { return }
                        await viewModel.loadFirstPage(client: client)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.current.backgroundColor.ignoresSafeArea())
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: StashScene.self) { scene in
                SceneDetailView(scene: scene)
            }
        }
        .task {
            guard viewModel.scenes.isEmpty, let client = appState.client else { return }
            await viewModel.loadFirstPage(client: client)
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

    /// Warm the preview-clip disk cache a short window ahead so playback is instant once the grid
    /// settles. Kept smaller than the thumbnail window since previews are full video files.
    private func prefetchPreviews(around scene: StashScene) {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }),
              let apiKey = appState.client?.apiKey else { return }
        let start = min(idx, viewModel.scenes.count - 1)
        let end = min(idx + 8, viewModel.scenes.count)
        guard start < end else { return }
        let urls = viewModel.scenes[start..<end].compactMap { $0.previewURL(apiKey: apiKey) }
        Task.detached(priority: .background) {
            await previewCache.prefetch(urls)
        }
    }
}

// MARK: - Scene card

struct SceneCard: View {
    let scene: StashScene
    let apiKey: String
    /// When non-nil, the preview clip plays in place over the thumbnail.
    var player: AVPlayer? = nil
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail layer: a fixed 16:9 frame the image fills + crops into (no distortion).
            Rectangle()
                .fill(themeManager.current.surfaceColor)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack {
                        if let img = thumbnail {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "film")
                                .font(.title2)
                                .foregroundStyle(themeManager.current.foregroundColor.opacity(0.25))
                        }
                        // Sits over the thumbnail; transparent until the first decoded frame.
                        if let player {
                            PlayerLayerView(player: player)
                        }
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                if let studio = scene.studio {
                    Text(studio.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(scene.title ?? "Untitled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let dur = scene.formattedDuration() {
                    Text(dur)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
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
