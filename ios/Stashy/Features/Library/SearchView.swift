import SwiftUI

@Observable
@MainActor
final class SearchViewModel {
    var query = ""
    var scenes: [Scene] = []
    var performers: [Performer] = []
    var isSearching = false
    private var searchTask: Task<Void, Never>?

    func search(client: StashClient) {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scenes = []
            performers = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            do {
                async let scenesResult = client.findScenes(page: 1, perPage: 20, query: q)
                async let performersResult = client.findPerformers(page: 1, perPage: 10, query: q)
                let (s, p) = try await (scenesResult, performersResult)
                scenes = s.scenes
                performers = p.performers
            } catch {
                // silently ignore search errors
            }
            isSearching = false
        }
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.imageCache) private var imageCache
    @State private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if !viewModel.scenes.isEmpty {
                    Section("Scenes") {
                        ForEach(viewModel.scenes) { scene in
                            NavigationLink(value: scene) {
                                SearchSceneRow(scene: scene, apiKey: appState.client?.apiKey ?? "")
                            }
                        }
                    }
                }

                if !viewModel.performers.isEmpty {
                    Section("Performers") {
                        ForEach(viewModel.performers) { performer in
                            PerformerRow(performer: performer, apiKey: appState.client?.apiKey ?? "")
                        }
                    }
                }

                if !viewModel.isSearching && viewModel.scenes.isEmpty && viewModel.performers.isEmpty
                    && !viewModel.query.isEmpty {
                    ContentUnavailableView.search(text: viewModel.query)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: Bindable(viewModel).query, prompt: "Search scenes and performers")
            .navigationDestination(for: Scene.self) { scene in
                SceneDetailView(scene: scene)
            }
            .onChange(of: viewModel.query) {
                guard let client = appState.client else { return }
                viewModel.search(client: client)
            }
        }
    }
}

struct SearchSceneRow: View {
    let scene: Scene
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img).resizable().scaledToFill()
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
                }
            }
        }
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            thumbnail = try? await imageCache.image(for: url)
        }
    }
}
