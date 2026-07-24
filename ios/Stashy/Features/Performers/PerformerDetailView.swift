import SwiftUI

struct PerformerDetailView: View {
    let performer: Performer
    @Binding var path: [Route]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LibraryEdits.self) private var edits
    @Environment(\.imageCache) private var imageCache
    @State private var loader = PaginatedLoader<StashScene>(pageSize: 24)
    @State private var query = SceneQuery()
    @State private var portrait: UIImage?
    @State private var previewPresenter = ScenePreviewPresenter()
    @State private var showImageViewer = false
    @State private var confirmDelete = false
    /// Metadata scrape/edit mini-sheet (••• menu).
    @State private var metadataMode: PerformerMetadataMode?
    /// Refetched after a metadata save so the header shows the new values without leaving the screen.
    @State private var refreshed: Performer?
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var apiKey: String { appState.client?.apiKey ?? "" }

    /// The freshest performer we have — the pushed value until a metadata save refetches.
    private var current: Performer { refreshed ?? performer }

    /// Reload this performer's scenes for the current filter.
    private func reload() async {
        guard let client = appState.client else { return }
        let q = query
        await loader.reload { page, perPage in
            let result = try await client.findScenes(q, page: page, perPage: perPage)
            return (result.scenes, result.count)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Text("Scenes")
                    .font(.headline)
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .padding(.horizontal, 12)

                SceneFilterBar(query: $query)

                if !loader.items.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(edits.visible(loader.items)) { scene in
                            SceneGridCell(
                                scene: scene,
                                apiKey: apiKey,
                                onOpen: { path.openScene($0) }
                            ) {
                                Task { await loader.loadNextIfNeeded(triggerID: scene.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                } else if loader.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else {
                    Text("No scenes match these filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                if loader.isLoading && !loader.items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.vertical, 12)
        }
        .onScrollPhaseChange { _, phase in
            setBrowseScrolling(
                phase != .idle,
                surface: "performer-scenes",
                phase: String(describing: phase)
            )
        }
        .onChange(of: loader.contentRevision, initial: true) { _, _ in
            prefetchNewestScenePage()
        }
        .themedBackground()
        .environment(\.scenePreviewPresenter, previewPresenter)
        .overlay { ScenePreviewOverlay(presenter: previewPresenter, onOpen: { path.openScene($0) }) }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        // No top-left back button (owner preference); rely on the edge-swipe, kept working via
        // EnableSwipeBack. Harmless in the Downloads fullScreenCover context — there it's the stack root
        // (swipe disabled by the helper's `count > 1` guard) and its own Close button is a separate item.
        .navigationBarBackButtonHidden(true)
        .background(EnableSwipeBack())
        .fullScreenCover(isPresented: $showImageViewer) {
            if let portrait {
                FullScreenImageViewer(image: portrait)
            }
        }
        // Metadata mini-window (scrape/edit). The sheet refetches the performer after saving and hands it
        // back, so the header + portrait update in place (portrait is keyed on image_path below).
        .sheet(item: $metadataMode) { mode in
            PerformerMetadataSheet(performerID: performer.id, mode: mode) { fresh in
                if let fresh { refreshed = fresh }
            }
        }
        .task {
            guard query.performerID == nil else { return }
            query.performerID = performer.id // triggers the initial load via onChange
        }
        .onChange(of: query) { _, _ in
            Task { await reload() }
        }
        // Keyed on image_path (not id) so a portrait changed by a metadata save reloads in place —
        // Stash stamps the path with a fresh cache-buster, and the refetch delivers the new path.
        .task(id: current.image_path) {
            guard let url = current.imageURL(apiKey: apiKey) else { return }
            portrait = try? await imageCache.image(for: url, priority: true)
        }
        .onDisappear { setBrowseScrolling(false) }
        .libraryEditErrorToast(edits)
        .confirmationDialog(
            "Delete this performer?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Performer Only", role: .destructive) {
                Task {
                    if await edits.deletePerformer(id: performer.id, client: appState.client) { dismiss() }
                }
            }
            Button("Delete Performer & All Their Scenes", role: .destructive) {
                Task {
                    guard let client = appState.client else { return }
                    let ids = (try? await client.sceneIDs(performerID: performer.id)) ?? []
                    if await edits.deletePerformer(id: performer.id, alsoScenes: ids, deleteFiles: true, client: client) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“Delete Performer Only” removes just \(performer.name); their scenes stay. “Delete Performer & All Their Scenes” also permanently deletes every scene featuring them, including the video files on disk — this can't be undone.")
        }
    }

    private func setBrowseScrolling(
        _ scrolling: Bool,
        surface: String = "performer-scenes",
        phase: String = "idle"
    ) {
        BrowseScrollCoordinator.shared.setScrolling(
            scrolling, surface: surface, phase: phase
        )
    }

    private func prefetchNewestScenePage() {
        let urls = loader.items.suffix(loader.pageSize).compactMap {
            $0.thumbnailURL(apiKey: apiKey)
        }
        guard !urls.isEmpty else { return }
        Task(priority: .background) {
            await imageCache.prefetch(urls: urls)
        }
    }

    // Portrait enlarged ~1.5x (was 120×160) and tappable to open the Photos-style fullscreen viewer.
    private let portraitWidth: CGFloat = 180
    private let portraitHeight: CGFloat = 240

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(current.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .privacyTitleBlur()
                Spacer(minLength: 8)
                FavoriteHeart(isFavorite: edits.isFavorite(current), size: 22, offColor: .secondary) { new in
                    edits.setPerformerFavorite(new, id: performer.id, client: appState.client)
                }
                PopupMenu(vertical: true, actions: [
                    PopupMenuAction(title: "Scrape Metadata", systemImage: "sparkle.magnifyingglass") {
                        metadataMode = .scrape
                    },
                    PopupMenuAction(title: "Edit Metadata", systemImage: "square.and.pencil") {
                        metadataMode = .edit
                    },
                    PopupMenuAction(title: "Delete Performer", systemImage: "trash", isDestructive: true) {
                        confirmDelete = true
                    }
                ])
            }
            .padding(.horizontal, 12)
            .zIndex(1)   // let the popup menu float above the content below

            StarRating(rating100: edits.rating(for: performer), starSize: 20) { new in
                edits.setPerformerRating(new, id: performer.id, client: appState.client)
            }
            .padding(.horizontal, 12)

            HStack(alignment: .top, spacing: 12) {
                Button { if portrait != nil { showImageViewer = true } } label: {
                    Group {
                        if let portrait {
                            Image(uiImage: portrait).resizable().scaledToFill()
                                .privacyImageBlur()
                        } else {
                            PerformerPlaceholder()
                        }
                    }
                    .frame(width: portraitWidth, height: portraitHeight)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.detail, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: CornerRadius.detail, style: .continuous))
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

            if let tags = current.tags, !tags.isEmpty {
                TagsCard(tags: tags)
                    .frame(height: 150)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var statItems: [(symbol: String, label: String, value: String)] {
        var out: [(String, String, String)] = []
        if let c = current.scene_count { out.append(("film.stack", "Scenes", "\(c)")) }
        if let age = current.age { out.append(("calendar", "Age", "\(age)")) }
        if let country = current.country, !country.isEmpty {
            out.append(("globe", "Country", "\(country.countryFlag) \(country)"))
        }
        if let gender = current.gender, !gender.isEmpty {
            out.append(("person.fill", "Gender", gender.capitalized))
        }
        if let birthdate = current.birthdate, !birthdate.isEmpty {
            out.append(("gift", "Born", birthdate))
        }
        return out.map { (symbol: $0.0, label: $0.1, value: $0.2) }
    }

    private var socialLinks: [SocialLink]? {
        let links = SocialLink.list(from: current.urls ?? [])
        return links.isEmpty ? nil : links
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

    /// Build the displayed link list from raw URL strings — deduplicated by URL and stable-sorted by
    /// priority. Used by BOTH the performer screen and the inline scene screen so they never disagree.
    static func list(from urls: [String]) -> [SocialLink] {
        let links = urls.compactMap { SocialLink(raw: $0) }
        var seen = Set<URL>()
        return links
            .filter { seen.insert($0.url).inserted }
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
    }
}
