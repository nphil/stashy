import SwiftUI

@Observable
@MainActor
final class SearchViewModel {
    var query = ""
    var scenes: [StashScene] = []
    var performers: [Performer] = []
    var tags: [Tag] = []
    var isSearching = false
    private var searchTask: Task<Void, Never>?

    func search(client: StashClient) {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scenes = []
            performers = []
            tags = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            // Scenes are matched on title and file path, so file-name searches work here too.
            async let scenesResult = client.findScenes(SceneQuery(search: q), page: 1, perPage: 20)
            async let performersResult = client.findPerformers(page: 1, perPage: 10, query: q)
            async let tagsResult = client.findTags(query: q, limit: 10)
            scenes = (try? await scenesResult)?.scenes ?? []
            performers = (try? await performersResult)?.performers ?? []
            tags = (try? await tagsResult) ?? []
            isSearching = false
        }
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var viewModel = SearchViewModel()

    private var hasResults: Bool {
        !viewModel.scenes.isEmpty || !viewModel.performers.isEmpty || !viewModel.tags.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.query.isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Find scenes and performers.")
                    )
                } else if viewModel.isSearching && !hasResults {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasResults {
                    ContentUnavailableView.search(text: viewModel.query)
                } else {
                    List {
                        if !viewModel.performers.isEmpty {
                            Section("Performers") {
                                ForEach(viewModel.performers) { performer in
                                    NavigationLink(value: performer) {
                                        PerformerRow(performer: performer, apiKey: appState.client?.apiKey ?? "")
                                    }
                                }
                            }
                        }
                        if !viewModel.tags.isEmpty {
                            Section("Tags") {
                                ForEach(viewModel.tags) { tag in
                                    NavigationLink(value: tag) {
                                        Label(tag.name, systemImage: "tag")
                                    }
                                }
                            }
                        }
                        if !viewModel.scenes.isEmpty {
                            Section("Scenes") {
                                ForEach(viewModel.scenes) { scene in
                                    NavigationLink(value: scene) {
                                        SearchSceneRow(scene: scene, apiKey: appState.client?.apiKey ?? "")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.current.backgroundColor.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: Bindable(viewModel).query, prompt: "Search scenes and performers")
            .navigationDestination(for: StashScene.self) { scene in
                SceneDetailView(scene: scene)
            }
            .navigationDestination(for: Performer.self) { performer in
                PerformerDetailView(performer: performer)
            }
            .navigationDestination(for: Tag.self) { tag in
                TagScenesView(tag: tag)
            }
            .onChange(of: viewModel.query) {
                guard let client = appState.client else { return }
                viewModel.search(client: client)
            }
        }
    }
}

struct SearchSceneRow: View {
    let scene: StashScene
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img).resizable().scaledToFill()
                        .blur(radius: blurThumbnails ? 18 : 0)
                } else {
                    Rectangle().fill(.tertiary)
                        .overlay { Image(systemName: "film").foregroundStyle(.quaternary) }
                }
            }
            .frame(width: 72, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(scene.title ?? "Untitled")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let studio = scene.studio {
                    Text(studio.name).font(.caption).foregroundStyle(.secondary)
                } else if let name = scene.files.first?.basename {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            thumbnail = try? await imageCache.image(for: url)
        }
    }
}

/// Scenes filtered to a single tag (pushed from search). Reuses the paginated scenes model.
struct TagScenesView: View {
    let tag: Tag
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var viewModel = ScenesViewModel()

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(viewModel.scenes) { scene in
                    NavigationLink(value: scene) {
                        SceneCard(scene: scene, apiKey: appState.client?.apiKey ?? "")
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        guard let client = appState.client else { return }
                        Task { await viewModel.loadNextPageIfNeeded(triggerID: scene.id, client: client) }
                    }
                }
            }
            .padding(12)

            if viewModel.isLoading {
                ProgressView().padding()
            }
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel.scenes.isEmpty, let client = appState.client else { return }
            viewModel.query.tags = [tag]
            await viewModel.loadFirstPage(client: client)
        }
    }
}
