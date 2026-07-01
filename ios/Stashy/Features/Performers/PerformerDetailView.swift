import SwiftUI

@Observable
@MainActor
final class PerformerScenesViewModel {
    var scenes: [StashScene] = []
    var query = SceneQuery()
    var isLoading = false
    var errorMessage: String?
    private var hasMore = true
    private var currentPage = 1
    let pageSize = 24

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

struct PerformerDetailView: View {
    let performer: Performer
    @Binding var path: [Route]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var viewModel = PerformerScenesViewModel()
    @State private var portrait: UIImage?
    @State private var previewPresenter = ScenePreviewPresenter()
    @State private var showImageViewer = false
    /// Optimistic rating/favorite, seeded from the performer; flip instantly and persist in the
    /// background, reverting only on server failure.
    @State private var rating100: Int?
    @State private var favorite: Bool
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    init(performer: Performer, path: Binding<[Route]>) {
        self.performer = performer
        _path = path
        _rating100 = State(initialValue: performer.rating100)
        _favorite = State(initialValue: performer.favorite ?? false)
    }

    private var apiKey: String { appState.client?.apiKey ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Text("Scenes")
                    .font(.headline)
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .padding(.horizontal, 12)

                SceneFilterBar(query: $viewModel.query)

                if !viewModel.scenes.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(viewModel.scenes) { scene in
                            SceneGridCell(
                                scene: scene,
                                apiKey: apiKey,
                                onOpen: { path.openScene($0) }
                            ) {
                                guard let client = appState.client else { return }
                                Task {
                                    await viewModel.loadNextPageIfNeeded(
                                        triggerID: scene.id,
                                        client: client
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                } else if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else {
                    Text("No scenes match these filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                if viewModel.isLoading && !viewModel.scenes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.vertical, 12)
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .environment(\.scenePreviewPresenter, previewPresenter)
        .overlay { ScenePreviewOverlay(presenter: previewPresenter, onOpen: { path.openScene($0) }) }
        .navigationTitle(performer.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showImageViewer) {
            if let portrait {
                FullScreenImageViewer(image: portrait)
            }
        }
        .task {
            guard viewModel.query.performerID == nil else { return }
            viewModel.query.performerID = performer.id // triggers the initial load via onChange
        }
        .onChange(of: viewModel.query) { _, _ in
            guard let client = appState.client else { return }
            Task { await viewModel.loadFirstPage(client: client) }
        }
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            portrait = try? await imageCache.image(for: url, priority: true)
        }
    }

    // Portrait enlarged ~1.5x (was 120×160) and tappable to open the Photos-style fullscreen viewer.
    private let portraitWidth: CGFloat = 180
    private let portraitHeight: CGFloat = 240

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(performer.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .blur(radius: blurTitles ? 6 : 0)
                Spacer(minLength: 8)
                FavoriteHeart(isFavorite: favorite, size: 22, offColor: .secondary, onToggle: setFavorite)
            }
            .padding(.horizontal, 12)

            StarRating(rating100: rating100, starSize: 20, onChange: setRating)
                .padding(.horizontal, 12)

            HStack(alignment: .top, spacing: 12) {
                Button { if portrait != nil { showImageViewer = true } } label: {
                    Group {
                        if let portrait {
                            Image(uiImage: portrait).resizable().scaledToFill()
                                .blur(radius: blurThumbnails ? 26 : 0)
                        } else {
                            PerformerPlaceholder()
                        }
                    }
                    .frame(width: portraitWidth, height: portraitHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                StatCard(items: statItems)
                    .frame(height: portraitHeight)
            }
            .padding(.horizontal, 12)

            if let links = socialLinks, !links.isEmpty {
                SocialsCard(links: links)
                    .frame(height: 130)
                    .padding(.horizontal, 12)
            }

            if let tags = performer.tags, !tags.isEmpty {
                TagsCard(tags: tags)
                    .frame(height: 150)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var statItems: [(symbol: String, label: String, value: String)] {
        var out: [(String, String, String)] = []
        if let c = performer.scene_count { out.append(("film.stack", "Scenes", "\(c)")) }
        if let age = performer.age { out.append(("calendar", "Age", "\(age)")) }
        if let country = performer.country, !country.isEmpty {
            out.append(("globe", "Country", "\(country.countryFlag) \(country)"))
        }
        if let gender = performer.gender, !gender.isEmpty {
            out.append(("person.fill", "Gender", gender.capitalized))
        }
        if let birthdate = performer.birthdate, !birthdate.isEmpty {
            out.append(("gift", "Born", birthdate))
        }
        return out.map { (symbol: $0.0, label: $0.1, value: $0.2) }
    }

    /// Optimistically apply a new rating, persist, and revert on failure.
    private func setRating(_ new: Int?) {
        let previous = rating100
        rating100 = new
        guard let client = appState.client else { return }
        Task { @MainActor in
            do { rating100 = try await client.setPerformerRating(id: performer.id, rating100: new) }
            catch { rating100 = previous }
        }
    }

    /// Optimistically toggle favorite, persist, and revert on failure.
    private func setFavorite(_ new: Bool) {
        let previous = favorite
        favorite = new
        guard let client = appState.client else { return }
        Task { @MainActor in
            do { favorite = try await client.setPerformerFavorite(id: performer.id, favorite: new) ?? new }
            catch { favorite = previous }
        }
    }

    private var socialLinks: [SocialLink]? {
        guard let urls = performer.urls else { return nil }
        // Stable sort by priority so Reddit / OnlyFans surface first.
        return urls.compactMap { SocialLink(raw: $0) }
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
    }
}

// MARK: - Social links

struct SocialLink {
    let url: URL
    let label: String
    let symbol: String
    /// Lower sorts first. Reddit and OnlyFans are prioritised.
    let priority: Int

    init?(raw: String) {
        guard let url = URL(string: raw), let host = url.host()?.lowercased() else { return nil }
        self.url = url
        switch true {
        case host.contains("reddit"):
            label = "Reddit"; symbol = "bubble.left.and.bubble.right.fill"; priority = 0
        case host.contains("onlyfans"):
            label = "OnlyFans"; symbol = "heart.fill"; priority = 1
        case host.contains("twitter"), host.contains("x.com"):
            label = "Twitter"; symbol = "bird"; priority = 2
        case host.contains("instagram"):
            label = "Instagram"; symbol = "camera"; priority = 2
        case host.contains("youtube"):
            label = "YouTube"; symbol = "play.rectangle"; priority = 2
        case host.contains("tiktok"):
            label = "TikTok"; symbol = "music.note"; priority = 2
        default:
            label = host.replacingOccurrences(of: "www.", with: ""); symbol = "link"; priority = 3
        }
    }
}
