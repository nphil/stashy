import SwiftUI

@Observable
@MainActor
final class PerformerScenesViewModel {
    var scenes: [StashScene] = []
    var isLoading = false
    var errorMessage: String?
    private var hasMore = true
    private var currentPage = 1
    let pageSize = 24

    func loadFirstPage(performerID: String, client: StashClient) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        currentPage = 1
        scenes = []
        hasMore = true
        await fetchPage(performerID: performerID, client: client)
        isLoading = false
    }

    func loadNextPageIfNeeded(triggerID: String, performerID: String, client: StashClient) async {
        guard hasMore, !isLoading,
              scenes.suffix(pageSize / 2).contains(where: { $0.id == triggerID })
        else { return }
        isLoading = true
        currentPage += 1
        await fetchPage(performerID: performerID, client: client)
        isLoading = false
    }

    private func fetchPage(performerID: String, client: StashClient) async {
        do {
            let result = try await client.findScenes(performerID: performerID, page: currentPage, perPage: pageSize)
            scenes.append(contentsOf: result.scenes)
            hasMore = scenes.count < result.count
        } catch {
            if currentPage > 1 { currentPage -= 1 }
            errorMessage = error.localizedDescription
        }
    }
}

struct PerformerDetailView: View {
    let performer: Performer
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var viewModel = PerformerScenesViewModel()
    @State private var portrait: UIImage?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var apiKey: String { appState.client?.apiKey ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !viewModel.scenes.isEmpty {
                    Text("Scenes")
                        .font(.headline)
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .padding(.horizontal, 12)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(viewModel.scenes) { scene in
                            NavigationLink(value: scene) {
                                SceneCard(scene: scene, apiKey: apiKey)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                guard let client = appState.client else { return }
                                Task {
                                    await viewModel.loadNextPageIfNeeded(
                                        triggerID: scene.id,
                                        performerID: performer.id,
                                        client: client
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                } else if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }

                if viewModel.isLoading && !viewModel.scenes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.vertical, 12)
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .navigationTitle(performer.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: StashScene.self) { scene in
            SceneDetailView(scene: scene)
        }
        .task {
            guard viewModel.scenes.isEmpty, let client = appState.client else { return }
            await viewModel.loadFirstPage(performerID: performer.id, client: client)
        }
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            portrait = try? await imageCache.image(for: url)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let portrait {
                    Image(uiImage: portrait).resizable().scaledToFill()
                } else {
                    Rectangle().fill(themeManager.current.surfaceColor)
                        .overlay { Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(performer.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(themeManager.current.foregroundColor)

                statsRow

                if let links = socialLinks, !links.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(links, id: \.url) { link in
                            Link(destination: link.url) {
                                Label(link.label, systemImage: link.symbol)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .glassEffect(.regular.tint(themeManager.current.accentColor), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    private var statsRow: some View {
        let items: [(String, String)] = {
            var out: [(String, String)] = []
            if let c = performer.scene_count { out.append(("film.stack", "\(c)")) }
            if let stars = performer.ratingStars { out.append(("star.fill", String(format: "%.1f", stars))) }
            if let country = performer.country, !country.isEmpty { out.append(("globe", country.countryFlag)) }
            if let age = performer.age { out.append(("calendar", "\(age)")) }
            return out
        }()
        return HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                Label(item.1, systemImage: item.0)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var socialLinks: [SocialLink]? {
        guard let urls = performer.urls else { return nil }
        return urls.compactMap { SocialLink(raw: $0) }
    }
}

// MARK: - Social links

struct SocialLink {
    let url: URL
    let label: String
    let symbol: String

    init?(raw: String) {
        guard let url = URL(string: raw), let host = url.host()?.lowercased() else { return nil }
        self.url = url
        switch true {
        case host.contains("twitter"), host.contains("x.com"):
            label = "Twitter"; symbol = "bird"
        case host.contains("instagram"):
            label = "Instagram"; symbol = "camera"
        case host.contains("onlyfans"):
            label = "OnlyFans"; symbol = "heart"
        case host.contains("youtube"):
            label = "YouTube"; symbol = "play.rectangle"
        case host.contains("tiktok"):
            label = "TikTok"; symbol = "music.note"
        case host.contains("reddit"):
            label = "Reddit"; symbol = "bubble.left"
        default:
            label = host.replacingOccurrences(of: "www.", with: ""); symbol = "link"
        }
    }
}
