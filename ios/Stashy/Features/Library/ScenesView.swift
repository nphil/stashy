import SwiftUI

@Observable
@MainActor
final class ScenesViewModel {
    var scenes: [Scene] = []
    var isLoading = false
    var errorMessage: String?
    private var hasMore = true
    private var currentPage = 1
    private let pageSize = 25

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
            scenes.append(contentsOf: result.scenes)
            hasMore = scenes.count < result.count
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
                    ContentUnavailableView(
                        "No Scenes",
                        systemImage: "film.stack",
                        description: Text("Your Stash library is empty.")
                    )
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
                }
            }
            .navigationTitle("Scenes")
            .navigationDestination(for: Scene.self) { scene in
                SceneDetailView(scene: scene)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            guard let client = appState.client else { return }
                            await viewModel.loadFirstPage(client: client)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            guard viewModel.scenes.isEmpty, let client = appState.client else { return }
            await viewModel.loadFirstPage(client: client)
        }
    }

    private func prefetchThumbnails(around scene: Scene) {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }),
              let apiKey = appState.client?.apiKey else { return }
        let start = min(idx + 1, viewModel.scenes.count - 1)
        let end = min(idx + pageSize, viewModel.scenes.count)
        guard start < end else { return }
        let urls = viewModel.scenes[start..<end].compactMap { $0.thumbnailURL(apiKey: apiKey) }
        Task.detached(priority: .background) {
            await imageCache.prefetch(urls: urls)
        }
    }
}

// MARK: - Scene card

struct SceneCard: View {
    let scene: Scene
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.tertiary)
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .overlay {
                            Image(systemName: "film")
                                .foregroundStyle(.quaternary)
                        }
                }
            }
            .clipped()

            // Gradient overlay + info
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

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
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            thumbnail = try? await imageCache.image(for: url)
        }
    }
}
