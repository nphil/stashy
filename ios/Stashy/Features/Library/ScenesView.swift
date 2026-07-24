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
    // Native list search: a minimized toolbar magnifier (top-right) that expands into the field on tap.
    // Debounced into query.search.
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var reloadDebounce: Task<Void, Never>?
    // A tag/sort change leaves the old grid visible while its replacement loads. Block scene navigation
    // during that window so a stale card cannot open just as its replacement page arrives.
    @State private var queryReloadGeneration = 0
    @State private var queryReloadPending = false
    // Bulk download (additive): fetch the whole filtered set, then pick one quality for all.
    @State private var bulkSheet = false
    @State private var bulkScenes: [StashScene] = []
    @State private var bulkLoading = false
    // Multi-select download (additive; off by default → zero cost during normal browsing).
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    // The jobs status dropdown (title button, top-leading). Mutually exclusive with the filter dropdown.
    @State private var jobsExpanded = false
    // Softens the nav-bar chrome (title button + funnel) reappearing after a detail pop: instead of the
    // custom toolbar content snapping in at the end of the swipe-back, it fades in. Driven by path→empty.
    @State private var chromeOpacity: Double = 1
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
            || query.usesReport
            || query.playability != .any
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
        // Report-backed filter (playability/resolution/fps/quality) OR report-backed sort (resolution/
        // framerate/quality): page over the plugin report's scene IDs, reordered by the sort key. Fetched by
        // ID and re-sorted after fetch (findScenesByIDs doesn't preserve order). Only when the report exists;
        // otherwise a native Stash sort handles resolution/framerate below.
        // Report path: a report FILTER is active, or the sort is Quality (no native Stash equivalent).
        // Resolution/frame-rate sorts WITHOUT a filter fall through to the native Stash sort below.
        if (q.usesReport || q.sort == .quality), PlayabilityStore.shared.isAvailable {
            let ids = PlayabilityStore.shared.matchingIDs(
                playability: q.playability, resolution: q.resolution, fps: q.fps, quality: q.quality)
            if q.sort.isReportSort {
                // The report carries the sort key (height / fps / quality score) → order the IDs and page by
                // ID (efficient, incremental).
                let sortedIDs = PlayabilityStore.shared.ordered(ids, by: q.sort, direction: q.direction)
                await loader.reload { page, perPage in
                    let start = (page - 1) * perPage
                    guard start < sortedIDs.count else { return ([], sortedIDs.count) }
                    let slice = Array(sortedIDs[start..<min(start + perPage, sortedIDs.count)])
                    let fetched = try await client.findScenesByIDs(slice)
                    let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    return (slice.compactMap { byID[$0] }, sortedIDs.count)   // restore sorted order
                }
            } else {
                // Native sort key (size/duration/date/title) within a report filter — the report can't order
                // it, so fetch the filtered set and sort CLIENT-SIDE, then page from the sorted array. Bounded
                // by the filtered set's size.
                var all: [StashScene] = []
                let chunk = 200
                var c = 0
                while c * chunk < ids.count {
                    let slice = Array(ids[(c * chunk)..<min((c + 1) * chunk, ids.count)])
                    if let s = try? await client.findScenesByIDs(slice) { all += s }
                    c += 1
                }
                let sorted = Self.sortScenes(all, by: q.sort, direction: q.direction)
                await loader.reload { page, perPage in
                    let start = (page - 1) * perPage
                    guard start < sorted.count else { return ([], sorted.count) }
                    return (Array(sorted[start..<min(start + perPage, sorted.count)]), sorted.count)
                }
            }
            return
        }
        // Only the unfiltered library is cached for offline browsing (a tag/filtered view offline would be
        // misleading). Save the first page on success; on an offline failure, fall back to the cache so the
        // grid still shows the library instead of an error.
        let cacheable = q.tags.isEmpty
        await loader.reload { page, perPage in
            do {
                let result = try await client.findScenes(q, page: page, perPage: perPage)
                if cacheable && page == 1 { LibraryCache.save(result.scenes) }
                return (result.scenes, result.count)
            } catch {
                if cacheable && page == 1 {
                    let cached = LibraryCache.load()
                    if !cached.isEmpty { return (cached, cached.count) }
                }
                throw error
            }
        }
    }

    /// Sort a fetched scene set by a `SceneSort` key, client-side — used when a report filter is active (so
    /// the filtered subset can be ordered by any key, including file size / duration that the report path
    /// otherwise couldn't). Quality reads the plugin report's score; createdAt has no field on the model so
    /// it proxies to date. Stable numeric-id tiebreak.
    @MainActor
    static func sortScenes(_ scenes: [StashScene], by sort: SceneSort, direction: SortDirection) -> [StashScene] {
        let asc = direction == .asc
        let stringKeyed = (sort == .title || sort == .date || sort == .createdAt)
        func str(_ s: StashScene) -> String {
            sort == .title ? (s.title ?? "").lowercased() : (s.date ?? "")
        }
        func num(_ s: StashScene) -> Double {
            let f = s.files.first
            switch sort {
            case .duration: return f?.duration ?? 0
            case .size: return Double(f?.size ?? 0)
            case .resolution: return Double(f?.height ?? 0)
            case .framerate: return f?.frame_rate ?? 0
            case .quality: return PlayabilityStore.shared.qscore(s.id)
            default: return 0
            }
        }
        return scenes.sorted { a, b in
            if stringKeyed {
                let ka = str(a), kb = str(b)
                if ka == kb { return (Int(a.id) ?? 0) < (Int(b.id) ?? 0) }
                return asc ? ka < kb : ka > kb
            }
            let ka = num(a), kb = num(b)
            if ka == kb { return (Int(a.id) ?? 0) < (Int(b.id) ?? 0) }
            return asc ? ka < kb : ka > kb
        }
    }

    /// Fetch EVERY scene matching the current filter (all pages), for a bulk download. Run at initiation
    /// (home WiFi), so paging the whole set is fine. Mirrors `reload`'s query paths (playability tier vs
    /// normal query). Additive — reads only, changes nothing about normal browsing.
    @MainActor
    private func allMatchingScenes() async -> [StashScene] {
        guard let client = appState.client else { return [] }
        let q = query
        if q.usesReport {
            let ids = PlayabilityStore.shared.matchingIDs(
                playability: q.playability, resolution: q.resolution, fps: q.fps, quality: q.quality)
            var out: [StashScene] = []
            let per = 100
            var page = 0
            while page * per < ids.count {
                let slice = Array(ids[(page * per)..<min((page + 1) * per, ids.count)])
                if let s = try? await client.findScenesByIDs(slice) { out += s }
                page += 1
            }
            return out
        }
        var out: [StashScene] = []
        var page = 1
        let per = 100
        while true {
            guard let result = try? await client.findScenes(q, page: page, perPage: per) else { break }
            out += result.scenes
            if result.scenes.isEmpty || out.count >= result.count { break }
            page += 1
        }
        return out
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    /// Download the selected scenes via the same options sheet as "Download all in filter".
    @MainActor
    private func startSelectionDownload() {
        let chosen = displayedScenes.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        bulkScenes = chosen
        bulkSheet = true
    }

    /// Gather the filtered set, then present the bulk options sheet (skips presenting on an empty result).
    @MainActor
    private func startBulkDownload() {
        guard !bulkLoading else { return }
        bulkLoading = true
        Task { @MainActor in
            let scenes = await allMatchingScenes()
            bulkScenes = scenes
            bulkLoading = false
            if !scenes.isEmpty { bulkSheet = true }
        }
    }

    // MARK: - Top-bar panels

    /// The filter panel with the old ⋯ actions (Download all / Select) folded in. Explicitly-typed optionals
    /// avoid a ternary-with-closure inference pitfall; the actions are suppressed in downloaded-only (nothing
    /// to bulk-download when everything shown is already local — matches the old ⋯-hidden behaviour).
    private var sceneFilterPanel: some View {
        let onDownloadAll: (() -> Void)? = query.downloadedOnly ? nil
            : { filterExpanded = false; startBulkDownload() }
        let onSelect: (() -> Void)? = query.downloadedOnly ? nil
            : { filterExpanded = false; selectionMode = true }
        return SceneFilterPanel(query: $query, onDownloadAll: onDownloadAll, onSelect: onSelect,
                                bulkLoading: bulkLoading)
    }

    /// The nav-bar title, as a button that drops the jobs panel down (top-leading). A chevron marks it
    /// tappable; it tints to the accent while the panel is open. Lives in the SYSTEM nav bar, so scrolling
    /// stays buttery (no custom glass over the grid) and the bar collapses natively.
    private var titleJobsButton: some View {
        Button {
            jobsExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Scenes").font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(jobsExpanded ? 180 : 0))
            }
            .foregroundStyle(jobsExpanded ? themeManager.current.accentColor : themeManager.current.foregroundColor)
            .animation(.snappy(duration: 0.28), value: jobsExpanded)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Swipe/tap the list to close either dropdown AND scroll in one motion (no modal backdrop).
                    .dismissesPopover($filterExpanded)
                    .dismissesPopover($jobsExpanded)
                // Both dropdowns are stable ZStack siblings of the churning `content` (they survive its
                // reload branch-flips — the FilterPopoverAnchor landmine) and exist only while open, so glass
                // never samples the scrolling grid per-frame. Jobs = top-leading (under the title button),
                // filter = top-trailing (under the funnel).
                LibraryDropdownPanel(isPresented: $jobsExpanded, anchor: .topLeading) {
                    JobsPanel(showActions: !query.downloadedOnly)
                }
                LibraryDropdownPanel(isPresented: $filterExpanded, anchor: .topTrailing) {
                    sceneFilterPanel
                }
            }
            // Only one dropdown open at a time.
            .onChange(of: filterExpanded) { _, open in if open { jobsExpanded = false } }
            .onChange(of: jobsExpanded) { _, open in if open { filterExpanded = false } }
            // Returned to the grid (a detail popped) → fade the custom nav chrome in instead of a hard pop.
            .onChange(of: path) { old, new in
                guard new.isEmpty, !old.isEmpty else { return }
                chromeOpacity = 0
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.35)) { chromeOpacity = 1 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            // Scene detail deliberately hides the navigation bar. The root must explicitly own a visible bar
            // so a rapid dropdown-dismiss + push/pop cannot leave the detail's hidden preference behind.
            .toolbar(.visible, for: .navigationBar)
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            // Native minimized search (magnifier → field), pinned top-right; debounced below.
            .searchable(text: $searchText, isPresented: $searchPresented, prompt: "Search scenes")
            .searchToolbarBehavior(.minimize)
            .task(id: searchText) {
                guard searchText != query.search else { return }
                try? await Task.sleep(for: .milliseconds(350))   // debounce; cancelled by the next keystroke
                guard !Task.isCancelled else { return }
                query.search = searchText                        // triggers the existing query reload
            }
            // Stable ToolbarItem identities with conditional CONTENT — swapping whole ToolbarItems behind an
            // if/else makes SwiftUI's toolbar builder drop them (the "button vanished" bug).
            .toolbar {
                // Match Performers: the interactive Jobs title lives at top-left and Cancel replaces its
                // content during selection. Keep the real navigationTitle above so this root still owns the
                // bar visibility after a detail push/pop.
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button("Cancel") { exitSelection() }
                            .opacity(chromeOpacity)
                    } else {
                        titleJobsButton
                            .opacity(chromeOpacity)
                    }
                }
                // A stable zero-size principal suppresses the duplicate centered navigationTitle chrome
                // without removing the real title that fixed the dropdown→player navigation-bar race.
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                // Search magnifier (top-right), then the funnel / selection-download button.
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    if selectionMode {
                        Button { startSelectionDownload() } label: {
                            Text("Download (\(selectedIDs.count))")
                                .fontWeight(.semibold)
                                .contentTransition(.numericText())   // count rolls as scenes are selected
                        }
                        .disabled(selectedIDs.isEmpty)
                        .animation(.snappy, value: selectedIDs.count)
                        .opacity(chromeOpacity)
                    } else {
                        FilterFunnelButton(expanded: $filterExpanded, isActive: filterActive)
                            .opacity(chromeOpacity)
                    }
                }
            }
            .sheet(isPresented: $bulkSheet) {
                BulkDownloadSheet(sceneCount: bulkScenes.count) { opts in
                    downloads.bulkDownload(scenes: bulkScenes, options: opts,
                                           apiKey: appState.client?.apiKey ?? "")
                    exitSelection()
                }
            }
            // While the sprite preview is up, hide the tab bar so its dim can darken the whole screen
            // (OLED-black), not just the content area.
            .toolbar(previewPresenter.active != nil ? .hidden : .automatic, for: .tabBar)
            .navigationDestination(for: Route.self) { route in
                // iOS 26's zoom transition holds its source card out of the grid after a pop. A native
                // push/pop keeps every return immediately scrollable and avoids per-card transition state.
                RouteDestination(route: route, path: $path)
            }
        }
        .environment(\.scenePreviewPresenter, previewPresenter)
        .overlay { ScenePreviewOverlay(presenter: previewPresenter, onOpen: openScene) }
        // Hide the status bar too, so the preview dim goes edge-to-edge black on an OLED screen.
        .statusBarHidden(previewPresenter.active != nil)
        // Debounced so rapid filter changes coalesce into one reload instead of an overlapping storm.
        .onChange(of: query) { _, _ in
            reloadDebounce?.cancel()
            queryReloadGeneration &+= 1
            let generation = queryReloadGeneration
            queryReloadPending = true
            reloadDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await reload()
                guard !Task.isCancelled, generation == queryReloadGeneration else { return }
                queryReloadPending = false
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
            // Load the plugin's served playability report (for smarter routing + the filter). Fire-and-
            // forget so it never delays the scene grid; no-op if the plugin isn't installed.
            Task { await PlayabilityStore.shared.refresh(serverURL: client.serverURL, apiKey: client.apiKey) }
            // Same for the served VMAF map — its per-scene target bitrates calibrate on-device transcodes.
            Task { await VmafMapStore.shared.refresh(serverURL: client.serverURL, apiKey: client.apiKey) }
            // And the served ThumbHash map — instant blur placeholders for scenes never opened on this device.
            Task { await ThumbHashStore.shared.refresh(serverURL: client.serverURL, apiKey: client.apiKey) }
            // And the served loudness map — per-scene gain for consistent volume across scenes.
            Task { await LoudnessStore.shared.refresh(serverURL: client.serverURL, apiKey: client.apiKey) }
            guard loader.items.isEmpty else { return }
            await reload()
        }
        .onDisappear {
            reloadDebounce?.cancel()
            queryReloadPending = false
            setBrowseScrolling(false)
        }
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
                            // In selection mode a tap toggles selection instead of opening the scene.
                            onOpen: { s in
                                if selectionMode { toggleSelection(s.id) } else { openScene(s) }
                            }
                        ) {
                            Task { await loader.loadNextIfNeeded(triggerID: scene.id) }
                        }
                        // Selection affordance — the `if selectionMode` short-circuits before reading
                        // `selectedIDs`, so normal browsing takes on no selection-tracking cost.
                        .overlay(alignment: .topTrailing) {
                            if selectionMode {
                                let on = selectedIDs.contains(scene.id)
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, on ? Color.accentColor : Color.black.opacity(0.35))
                                    .padding(6)
                            }
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
            .onScrollPhaseChange { _, phase in
                setBrowseScrolling(
                    phase != .idle,
                    surface: "scenes",
                    phase: String(describing: phase)
                )
            }
            .onChange(of: loader.contentRevision, initial: true) { _, _ in
                prefetchNewestScenePage()
            }
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
                            onOpen: openScene
                        ) {}
                    }
                }
                .padding(12)
            }
            .onScrollPhaseChange { _, phase in
                setBrowseScrolling(
                    phase != .idle,
                    surface: "downloaded-scenes",
                    phase: String(describing: phase)
                )
            }
        }
    }

    /// Seed each fetched page into the bounded image queue once. This replaces the old per-card
    /// firstIndex/suffix scan and gives every page's thumbnails a head start before a fast fling reaches it.
    private func prefetchNewestScenePage() {
        guard let apiKey = appState.client?.apiKey else { return }
        let urls = loader.items.suffix(loader.pageSize).compactMap {
            $0.thumbnailURL(apiKey: apiKey)
        }
        guard !urls.isEmpty else { return }
        Task(priority: .background) {
            await imageCache.prefetch(urls: urls)
        }
    }

    private func setBrowseScrolling(
        _ scrolling: Bool,
        surface: String = "scenes",
        phase: String = "idle"
    ) {
        BrowseScrollCoordinator.shared.setScrolling(
            scrolling, surface: surface, phase: phase
        )
    }

    /// Open only from a stable grid. Query reloads deliberately keep the previous page visible; allowing one
    /// of those stale cards to navigate just as the async replacement lands can race navigation-bar state.
    private func openScene(_ scene: StashScene) {
        guard !queryReloadPending, !filterExpanded, !jobsExpanded else { return }
        path.append(.scene(scene))
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
    @State private var thumbnail: UIImage?

    /// Rating on a 0–5 scale, reading through the edits store so a rating set on the detail screen
    /// shows here immediately.
    private var ratingStars: Double? {
        guard let r = edits.rating(for: scene) else { return nil }
        return Double(r) / 20.0
    }

    var body: some View {
        // One indexed-array walk per body, not separate `localFile` + `wasTranscoded` walks. This matters
        // when a large downloads library is consulted as each new scene card enters the viewport.
        let downloadStatus = downloads.cardStatus(sceneID: scene.id)

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
                            .privacyImageBlur()
                    } else if let ph = ThumbHashStore.shared.placeholder(for: scene.id) {
                        // Instant blurry preview from the tiny ThumbHash while the real thumbnail loads.
                        Image(uiImage: ph)
                            .resizable()
                            .scaledToFill()
                            .privacyImageBlur()
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
                                .overlayBadge()
                        }
                        // Offline status, tucked under the duration: green = downloaded, accent = transcoded.
                        if downloadStatus.isDownloaded {
                            HStack(spacing: 4) {
                                if downloadStatus.wasTranscoded {
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
                        .overlayBadge()
                        .padding(6)
                    }
                }
                .clipped()

            Text(scene.title ?? "Untitled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .privacyTitleBlur()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .cardContour(isDark: themeManager.current.preferredColorScheme == .dark)
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            // Publish memory hits synchronously at task start; otherwise keep the persistent disk/network
            // request moving during inertia and replace the ThumbHash immediately when it finishes.
            if let cached = imageCache.cachedImage(for: url) {
                thumbnail = cached
                BrowseScrollCoordinator.shared.recordThumbnailPublication(
                    loadMilliseconds: 0, memoryHit: true
                )
                return
            }
            let started = Date()
            let loaded = try? await imageCache.image(for: url)
            guard !Task.isCancelled, let loaded else { return }
            thumbnail = loaded
            BrowseScrollCoordinator.shared.recordThumbnailPublication(
                loadMilliseconds: Date().timeIntervalSince(started) * 1_000,
                memoryHit: false
            )
            ThumbHashStore.shared.ingest(loaded, for: scene.id)
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
