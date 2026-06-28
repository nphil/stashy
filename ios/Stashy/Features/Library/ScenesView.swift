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
    @Environment(ThemeManager.self) private var themeManager
    @State private var viewModel = ScenesViewModel()

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
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
                                NavigationLink(value: scene) {
                                    SceneCard(scene: scene, apiKey: appState.client?.apiKey ?? "")
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    guard let client = appState.client else { return }
                                    Task {
                                        await viewModel.loadNextPageIfNeeded(
                                            triggerID: scene.id,
                                            client: client
                                        )
                                    }
                                    // Prefetch thumbnails for next batch
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
}

// MARK: - Scene card

struct SceneCard: View {
    let scene: StashScene
    let apiKey: String
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
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(themeManager.current.foregroundColor.opacity(0.25))
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
        // Native long-press peek shows the Stash preview clip; tap still navigates, scroll works.
        .contextMenu {
            EmptyView()
        } preview: {
            Group {
                if let previewURL = scene.previewURL(apiKey: apiKey) {
                    ScenePreviewView(url: previewURL)
                } else if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: 360, height: 202)
        }
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            thumbnail = try? await imageCache.image(for: url)
        }
    }
}

// MARK: - Looping muted scene preview (long-press)

/// Plays a Stash scene preview clip, muted and looping, filling its frame. No controls.
struct ScenePreviewView: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let player {
                PlayerLayerView(player: player)
            } else {
                Color.black
            }
        }
        .onAppear {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
        }
    }
}

/// A thin `AVPlayerLayer`-backed view that fills + crops without playback controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
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
