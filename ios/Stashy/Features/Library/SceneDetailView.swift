import SwiftUI

struct SceneDetailView: View {
    let scene: StashScene
    @Binding var path: [Route]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LibraryEdits.self) private var edits
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var isFullscreen = false
    @State private var quality: ServerQuality = .auto   // gear-menu manual server-transcode override
    @State private var resumeAt: Double = 0             // position carried across a quality switch
    @State private var confirmDelete = false
    /// The scene list query slims performers to id+name to keep the payload small. Once the detail
    /// screen appears we re-fetch this one scene's full performer profiles (rating, urls, tags…) for
    /// the performer card and social links. Nil until the fetch lands; falls back to the slim scene.
    @State private var fullScene: StashScene?

    /// Full performers if the detail fetch has landed, otherwise the slim (id+name) list.
    private var performers: [Performer] { (fullScene ?? scene).performers }

    private var route: PlaybackRoute? {
        // Manual server-quality override (gear menu) wins over everything — force the Stash HLS transcode
        // at the chosen resolution.
        if quality != .auto, let client = appState.client,
           let q = scene.serverQualityRoute(quality: quality, apiKey: client.apiKey) {
            return q
        }
        // Prefer a completed download: play the local file offline. Route it through the same codec/
        // container capability check as the server stream, so a downloaded HEVC / foreign-container file
        // goes through the on-device remux (of the local file) instead of a bare AVPlayer that can't
        // decode it.
        if let local = downloads.localFile(sceneID: scene.id) {
            return scene.localPlaybackRoute(localURL: local, apiKey: appState.client?.apiKey ?? "",
                                            nativeMP4: downloads.wasTranscoded(sceneID: scene.id))
        }
        guard let client = appState.client else { return nil }
        return scene.playbackRoute(apiKey: client.apiKey,
                                   pluginNeedsTranscode: PlayabilityStore.shared.needsTranscode(scene.id))
    }

    var body: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            // Inline player box is sized for 16:9 (full width), so a 16:9 video fills it exactly with
            // no top/bottom blur. Other aspect ratios fit inside this box (blur fills the gaps). The
            // player also extends up behind the status bar, where the blurred backdrop blends in.
            let boxHeight = geo.size.width * 9 / 16

            ZStack(alignment: .top) {
                // Fixed (no-scroll) layout: player up top, compact metadata fills the rest.
                VStack(spacing: 0) {
                    Color.clear.frame(height: boxHeight)
                    metadata
                }
                .opacity(isFullscreen ? 0 : 1)

                // Single player instance — resized in place for fullscreen (no re-parenting), which
                // keeps the render surface alive across the rotation that previously blanked it.
                Group {
                    if let route {
                        // Privacy Mode blurs the video (inline + fullscreen); press-and-hold to peek.
                        PrivacyPeek {
                            ScenePlayerView(
                                scene: scene,
                                apiKey: apiKey,
                                route: route,
                                safeArea: geo.safeAreaInsets,
                                isFullscreen: $isFullscreen,
                                quality: $quality,
                                resumeTime: $resumeAt,
                                onBack: { dismiss() }
                            )
                            // Rebuild the player (and its ScenePlayerModel, whose route is a `let` set once at
                            // init) whenever the resolved source changes — e.g. a download/transcode completes
                            // while the scene is open, flipping the route from the online stream to the local
                            // file. Fullscreen toggles don't change the URL, so the in-place resize is intact.
                            .id(route.url)
                        }
                    } else {
                        Rectangle()
                            .fill(.black)
                            .overlay { ProgressView().tint(.white) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : boxHeight + topInset, alignment: .top)
                .ignoresSafeArea(edges: isFullscreen ? .all : .top)
            }
            // Smooth fullscreen flip: animate the player box + metadata fade with the rotation. The
            // embedded ZoomablePlayerSurface opts OUT of this animation via `.transaction { $0.animation
            // = nil }` (see ScenePlayerView), so its zoom setup stays deterministic and pinch-zoom keeps
            // working — the box glides while the scroll internals commit instantly.
            .animation(.easeInOut(duration: 0.3), value: isFullscreen)
        }
        .themedBackground()
        .toolbar(.hidden, for: .navigationBar)
        // Hide the tab bar for the whole scene screen, not just in fullscreen. Toggling tab-bar
        // visibility *in place* is unreliable: SwiftUI only re-applies it on a navigation push/pop or an
        // orientation change, so landscape fullscreen (which rotates) hid it but portrait fullscreen
        // (button-triggered, no rotation) left it showing. Hiding unconditionally binds the change to
        // push/pop, which always works — and a dedicated player/detail screen doesn't need the tab bar.
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(isFullscreen)
        .background(EnableSwipeBack()) // keep edge-swipe back even with the nav bar hidden
        // Restore portrait when the whole detail screen goes away (back / swipe-back / open performer).
        // This lives here — not in ScenePlayerView — because the player is rebuilt on every quality
        // switch (`.id(route.url)`); resetting orientation there would kick fullscreen back to portrait.
        .onDisappear { OrientationController.lock(.portrait) }
        .task(id: scene.id) {
            guard let client = appState.client else { return }
            fullScene = try? await client.findScene(id: scene.id)
        }
        .libraryEditErrorToast(edits)
        .confirmationDialog(
            "Delete this scene?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Scene & File", role: .destructive) {
                Task {
                    if await edits.deleteScene(id: scene.id, deleteFile: true, client: appState.client) { dismiss() }
                }
            }
            Button("Remove from Stash Only", role: .destructive) {
                Task {
                    if await edits.deleteScene(id: scene.id, deleteFile: false, client: appState.client) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“Delete Scene & File” permanently deletes the video file from disk — this can't be undone. “Remove from Stash Only” keeps the file and just removes the scene from your library.")
        }
    }

    private var metadata: some View {
        let spacing: CGFloat = 10
        return GeometryReader { geo in
            // Top row (performer + socials) is sized so the enlarged performer card reaches at least
            // the bottom of the socials card; the tags card then fills down to just above the specs box.
            let topRowHeight = min(max(geo.size.height * 0.46, 170), 230)
            VStack(spacing: spacing) {
                // Title + studio + date (left) with the star rating anchored trailing.
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scene.title ?? "Untitled")
                            .font(.headline)
                            .foregroundStyle(themeManager.current.foregroundColor)
                            .lineLimit(1)
                            .privacyTitleBlur()
                        // Rating stars sit under the title (replacing the old studio line); the date trails.
                        HStack(spacing: 8) {
                            StarRating(rating100: edits.rating(for: scene), starSize: 18) { new in
                                edits.setSceneRating(new, id: scene.id, client: appState.client)
                            }
                            if let date = scene.date {
                                Text(date).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PopupMenu(vertical: true, actions: [
                        PopupMenuAction(title: "Download Video", systemImage: "arrow.down.circle") {
                            // Stage it (don't start) — the Downloads card lets you pick source / threads /
                            // server resolution, then Start.
                            downloads.stage(scene: fullScene ?? scene, apiKey: apiKey)
                            path.append(.downloads)
                        },
                        PopupMenuAction(title: "Delete Scene", systemImage: "trash", isDestructive: true) {
                            confirmDelete = true
                        }
                    ])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)   // let the popup menu float above the cards below

                // Performer card (left, enlarged) + socials stack (right, truncated to fit).
                HStack(alignment: .top, spacing: spacing) {
                    ScenePerformerCard(performers: performers, apiKey: apiKey) { performer in
                        path.openPerformer(performer)
                    }
                    .frame(width: 150, height: topRowHeight)
                    SocialsCard(links: socialLinks ?? [])
                        .frame(maxWidth: .infinity)
                        .frame(height: topRowHeight)
                }

                // Tags card — full width of the two cards above, scrolls internally when it overflows.
                TagsCard(tags: scene.tags)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                techBox
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.top, spacing)
            .padding(.bottom, 12)
        }
    }

    private var socialLinks: [SocialLink]? {
        // Same builder as the performer screen (dedup + priority sort) so the two never disagree — here
        // aggregated across all of the scene's performers.
        let links = SocialLink.list(from: performers.flatMap { $0.urls ?? [] })
        return links.isEmpty ? nil : links
    }

    private var techItems: [(label: String, symbol: String)] {
        var out: [(String, String)] = []
        if let r = scene.resolutionLabel { out.append((r, "rectangle.compress.vertical")) }
        if let ar = scene.aspectRatioLabel { out.append((ar, "aspectratio")) }
        if let c = scene.codecLabel { out.append((c, "film")) }
        if let b = scene.bitrateLabel { out.append((b, "speedometer")) }
        if let f = scene.frameRateLabel { out.append((f, "timelapse")) }
        if let d = scene.formattedDuration() { out.append((d, "clock")) }
        if let s = scene.fileSizeLabel { out.append((s, "internaldrive")) }
        return out
    }

    @ViewBuilder private var techBox: some View {
        let items = techItems
        if !items.isEmpty {
            FlowLayout(spacing: 10) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 9))
                        Text(item.label)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var apiKey: String { appState.client?.apiKey ?? "" }
}

/// Enlarged, left-aligned performer card for the scene screen: a large portrait of the primary
/// performer with name + age · country overlaid, tappable to open the performer. A "+N" badge marks
/// scenes with extra performers.
struct ScenePerformerCard: View {
    let performers: [Performer]
    let apiKey: String
    var onOpen: (Performer) -> Void
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(LibraryEdits.self) private var edits
    @State private var image: UIImage?

    var body: some View {
        if let performer = performers.first {
            // Tap opens the performer; the favorite heart is overlaid as a separate hit target (not a
            // nested button) so its tap never conflicts with the open gesture.
            ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(themeManager.current.surfaceColor)
                        .overlay {
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .privacyImageBlur()
                            } else {
                                PerformerPlaceholder()
                            }
                        }
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center, endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(performer.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .privacyTitleBlur()
                        HStack(spacing: 5) {
                            if let age = performer.age { Text("\(age)") }
                            if let country = performer.country, !country.isEmpty { Text(country.countryFlag) }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(10)

                    if performers.count > 1 {
                        Text("+\(performers.count - 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlayBadge()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    FavoriteHeart(isFavorite: edits.isFavorite(performer), size: 16) { newValue in
                        edits.setPerformerFavorite(newValue, id: performer.id, client: appState.client)
                    }
                    .padding(8)
                }
                .onTapGesture { onOpen(performer) }
                // Key on image_path, not id: the scene list provides slim performers (no image_path), and
                // the full performer arrives later with the *same* id — keying on the path re-fires the load
                // when the path finally appears (otherwise the portrait never loads until the view is rebuilt).
                .task(id: performer.image_path) {
                    guard let url = performer.imageURL(apiKey: apiKey) else { return }
                    image = try? await imageCache.image(for: url, priority: true)
                }
        } else {
            PerformerPlaceholder()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Flow layout (wrapping chip row)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, in: proposal.replacingUnspecifiedDimensions())
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.size)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(subviews: Subviews, in size: CGSize) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        var maxX: CGFloat = 0

        for subview in subviews {
            let viewSize = subview.sizeThatFits(.unspecified)
            if x + viewSize.width > size.width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: viewSize))
            rowHeight = max(rowHeight, viewSize.height)
            x += viewSize.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}
