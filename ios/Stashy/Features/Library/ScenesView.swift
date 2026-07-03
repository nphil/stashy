import SwiftUI
import AVFoundation

struct ScenesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router
    @Environment(LibraryEdits.self) private var edits
    @Environment(DownloadManager.self) private var downloads
    @State private var loader = PaginatedLoader<StashScene>(pageSize: 25)
    @State private var query = SceneQuery()
    @State private var path: [Route] = []
    @State private var previewPresenter = ScenePreviewPresenter()
    @State private var filterExpanded = false
    @State private var reloadDebounce: Task<Void, Never>?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    // Sort (field + direction) persists across launches; filters (tags) always start cleared.
    init() {
        var q = SceneQuery()
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "sort.scenes.field"), let s = SceneSort(rawValue: raw) { q.sort = s }
        if let raw = d.string(forKey: "sort.scenes.dir"), let dir = SortDirection(rawValue: raw) { q.direction = dir }
        _query = State(initialValue: q)
    }

    private var filterActive: Bool {
        !query.tags.isEmpty || query.sort != .date || query.direction != .desc || query.downloadedOnly
    }

    /// Scenes to show: the downloaded-only view reads completed downloads locally (no network),
    /// otherwise the paginated library results. Both pass through `edits.visible` so deletes/overrides
    /// apply.
    private var displayedScenes: [StashScene] {
        if query.downloadedOnly {
            return edits.visible(downloads.items.filter { $0.state == .completed }.compactMap(\.scene))
        }
        return edits.visible(loader.items)
    }

    /// Reload the first page for the current query. Called on appear and on every query change.
    private func reload() async {
        // Downloaded-only is served entirely from local state — no library fetch.
        guard !query.downloadedOnly else { return }
        guard let client = appState.client else { return }
        let q = query
        await loader.reload { page, perPage in
            let result = try await client.findScenes(q, page: page, perPage: perPage)
            return (result.scenes, result.count)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topTrailing) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The popover is hosted from a *stable sibling* of `content`, never as an overlay on it.
                // `content` flips its `@ViewBuilder` branch (grid ⇄ full-screen spinner ⇄ empty state)
                // every time a reload clears `items`; a popover attached to that churning subtree is torn
                // down and re-presented on each branch flip — exactly the "tap a tag → window closes and
                // reopens" bug. As a peer in the ZStack the anchor keeps its identity regardless of which
                // branch `content` renders, so the popover stays put across reloads.
                FilterPopoverAnchor(isPresented: $filterExpanded) {
                    SceneFilterPanel(query: $query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.current.backgroundColor.ignoresSafeArea())
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
        // Debounced so rapid filter changes coalesce into one reload instead of an overlapping storm.
        .onChange(of: query) { _, _ in
            reloadDebounce?.cancel()
            reloadDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .onChange(of: query.sort) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "sort.scenes.field") }
        .onChange(of: query.direction) { _, dir in UserDefaults.standard.set(dir.rawValue, forKey: "sort.scenes.dir") }
        // A tag tapped elsewhere filters scenes to just that tag (pops to the grid).
        .onChange(of: router.sceneTagFilter) { _, tag in
            guard let tag else { return }
            path = []
            query = SceneQuery(tags: [tag])
            router.sceneTagFilter = nil
        }
        .task {
            guard let client = appState.client else { return }
            Task { await TagRankingStore.shared.refreshIfNeeded(client: client) }
            guard loader.items.isEmpty else { return }
            await reload()
        }
        .onDisappear { reloadDebounce?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if query.downloadedOnly {
            downloadedContent
        } else if loader.items.isEmpty && loader.isLoading {
            ProgressView("Loading scenes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loader.items.isEmpty && !loader.isLoading {
            if let err = loader.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Scenes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Retry") { Task { await reload() } }
                }
            } else if !query.tags.isEmpty {
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
                    ForEach(displayedScenes) { scene in
                        SceneGridCell(
                            scene: scene,
                            apiKey: appState.client?.apiKey ?? "",
                            onOpen: { path.append(.scene($0)) }
                        ) {
                            Task { await loader.loadNextIfNeeded(triggerID: scene.id) }
                            prefetchThumbnails(around: scene)
                        }
                    }
                }
                .padding(12)

                if loader.isLoading {
                    ProgressView()
                        .padding()
                }
            }
            .refreshable { await reload() }
        }
    }

    /// Downloaded-only view: a grid of completed offline scenes, or an empty state when none exist.
    @ViewBuilder
    private var downloadedContent: some View {
        let scenes = displayedScenes
        if scenes.isEmpty {
            ContentUnavailableView(
                "No Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download a scene from its ••• menu to watch it offline.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(scenes) { scene in
                        SceneGridCell(
                            scene: scene,
                            apiKey: appState.client?.apiKey ?? "",
                            onOpen: { path.append(.scene($0)) }
                        ) {}
                    }
                }
                .padding(12)
            }
        }
    }

    private func prefetchThumbnails(around scene: StashScene) {
        guard let idx = loader.items.firstIndex(where: { $0.id == scene.id }),
              let apiKey = appState.client?.apiKey else { return }
        let start = min(idx + 1, loader.items.count - 1)
        let end = min(idx + loader.pageSize, loader.items.count)
        guard start < end else { return }
        let urls = loader.items[start..<end].compactMap { $0.thumbnailURL(apiKey: apiKey) }
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
    @Environment(DownloadManager.self) private var downloads
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var thumbnail: UIImage?

    private var isDownloaded: Bool { downloads.localFile(sceneID: scene.id) != nil }
    private var wasTranscoded: Bool { downloads.wasTranscoded(sceneID: scene.id) }

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
                    VStack(alignment: .trailing, spacing: 4) {
                        if let dur = scene.formattedDuration() {
                            Text(dur)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        // Offline status, tucked under the duration: green = downloaded, accent = transcoded.
                        if isDownloaded {
                            HStack(spacing: 4) {
                                if wasTranscoded {
                                    statusIcon("wand.and.stars", tint: themeManager.current.accentColor)
                                }
                                statusIcon("arrow.down.circle.fill", tint: .green)
                            }
                        }
                    }
                    .padding(6)
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

    private func statusIcon(_ system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
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
