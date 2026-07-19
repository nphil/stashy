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
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var apiKey: String { appState.client?.apiKey ?? "" }

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
        .themedBackground()
        .environment(\.scenePreviewPresenter, previewPresenter)
        .overlay { ScenePreviewOverlay(presenter: previewPresenter, onOpen: { path.openScene($0) }) }
        .navigationTitle(performer.name)
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
        .task {
            guard query.performerID == nil else { return }
            query.performerID = performer.id // triggers the initial load via onChange
        }
        .onChange(of: query) { _, _ in
            Task { await reload() }
        }
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            portrait = try? await imageCache.image(for: url, priority: true)
        }
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

    // Portrait enlarged ~1.5x (was 120×160) and tappable to open the Photos-style fullscreen viewer.
    private let portraitWidth: CGFloat = 180
    private let portraitHeight: CGFloat = 240

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(performer.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .privacyTitleBlur()
                Spacer(minLength: 8)
                FavoriteHeart(isFavorite: edits.isFavorite(performer), size: 22, offColor: .secondary) { new in
                    edits.setPerformerFavorite(new, id: performer.id, client: appState.client)
                }
                PopupMenu(vertical: true, actions: [
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

    private var socialLinks: [SocialLink]? {
        let links = SocialLink.list(from: performer.urls ?? [])
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
