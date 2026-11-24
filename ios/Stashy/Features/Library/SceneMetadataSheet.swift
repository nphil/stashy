import SwiftUI

/// How the scene metadata sheet opens from the ••• menu: straight into the edit form, or auto-scrape
/// all sources first and land on the merged form.
enum SceneMetadataMode: String, Identifiable {
    case edit, scrape
    var id: String { rawValue }
}

/// The scene metadata "mini window": a medium-detent glass sheet floating over the playing video.
/// A single EDIT FORM (title / date / details / studio / performers / tags / cover). "Scrape Metadata"
/// queries **all three configured sources (StashDB / ThePornDB / FansDB) in parallel** and merges the
/// results straight into this form — where the sources agree, the value just fills in; where they
/// disagree (e.g. a different title or studio), a row of source chips appears so you pick the right one.
/// Tags and performers union across sources (deduplicated); unmatched entities become dashed "+" chips
/// you can create on tap. Nothing touches the server until Save.
struct SceneMetadataSheet: View {
    let sceneID: String
    let mode: SceneMetadataMode
    /// Handed the freshly-refetched scene after a successful save so the detail screen updates in place.
    var onSaved: (StashScene?) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// A studio/performer/tag reference in the form. `storedID` nil = scraped entity not in the library
    /// yet (rendered dashed; tap-to-create fills the id in). Uncreated entries are skipped on Save.
    private struct EntityRef: Identifiable, Hashable {
        var storedID: String?
        let name: String
        var scrapedPerformer: StashScraper.ScrapedPerformerData?

        init(storedID: String?, name: String,
             scrapedPerformer: StashScraper.ScrapedPerformerData? = nil) {
            self.storedID = storedID
            self.name = name
            self.scrapedPerformer = scrapedPerformer
        }
        var id: String { storedID ?? "new:\(name)" }
    }

    /// One studio candidate for the conflict chips (carries the local id when a source matched one).
    private struct StudioOption: Identifiable, Hashable {
        let source: String
        let storedID: String?
        let name: String
        var id: String { source + "\u{1}" + name }
    }

    @State private var loaded = false
    @State private var loadError: String?

    // Form state (seeded from a fresh findScene fetch — richer than the app's slim list model).
    @State private var title = ""
    @State private var date = ""
    @State private var details = ""
    @State private var urls: [String] = []
    @State private var studio: EntityRef?
    @State private var performers: [EntityRef] = []
    @State private var tags: [EntityRef] = []
    @State private var screenshotPath: String?
    @State private var coverOverride: String?      // scraped base64/URL cover, applied on Save
    @State private var existingStashIDs: [StashScraper.StashIDPair] = []
    @State private var pendingStashIDs: [StashScraper.StashIDPair]?

    // Per-field conflict options (populated by a scrape; empty = nothing to choose).
    @State private var titleOptions: [SourcedValue] = []
    @State private var dateOptions: [SourcedValue] = []
    @State private var detailsOptions: [SourcedValue] = []
    @State private var studioOptions: [StudioOption] = []
    @State private var coverOptions: [SourcedValue] = []   // value = image string; "Current" = keep

    @State private var scraping = false
    @State private var phase: ScrapePhase = .idle

    // Tag add-search.
    @State private var tagSearch = ""
    @State private var tagResults: [Tag] = []

    @State private var saving = false
    @State private var saveError: String?

    // Ranked by-name search (community scrapers), run when no stash-box matched the fingerprint.
    private struct FormSnapshot {
        let title: String
        let date: String
        let details: String
        let urls: [String]
        let studio: EntityRef?
        let performers: [EntityRef]
        let tags: [EntityRef]
        let coverOverride: String?
        let pendingStashIDs: [StashScraper.StashIDPair]?
    }
    private static let fingerprintHow = "by this scene's file fingerprints"

    @State private var fileBasename: String?
    @State private var nameQuery = ""                                  // editable search term
    @State private var nameScrapers: [StashScraper.Source] = []         // ranked, installed, NAME-capable
    @State private var nameCursor = 0                                  // next scraper to try
    @State private var nameProgress: StashScraper.ScrapeProgress?       // fingerprint rows + ranked rows
    @State private var fingerprintProgress: StashScraper.ScrapeProgress? // the stash-box pass, if it ran
    @State private var nameHits: [StashScraper.SourcedScene] = []
    @State private var pickerOpen = false
    @State private var resolvingHit: Int?
    @State private var baseline: FormSnapshot?                         // form before the first pick
    @State private var searchTask: Task<Void, Never>?
    @State private var pickTask: Task<Void, Never>?

    private var scraper: StashScraper? {
        appState.client.map { StashScraper(client: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: "Scene Metadata",
                actionTitle: "Save",
                actionDisabled: !loaded || saving || scraping || resolvingHit != nil,
                busy: saving,
                onCancel: { dismiss() },
                onAction: { save() }
            )

            if let loadError {
                SheetErrorLine(message: loadError)
            }

            if pickerOpen {
                SceneCandidatePicker(
                    hits: nameHits,
                    resolving: resolvingHit,
                    remaining: max(0, nameScrapers.count - nameCursor),
                    query: $nameQuery,
                    onPick: { choose($0) },
                    onKeepSearching: { keepSearching() },
                    onSearch: { searchAgain() },
                    onDismiss: { pickerOpen = false })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if phase != .idle {
                ScrapeStatusCard(
                    phase: phase,
                    hint: statusHint,
                    onRetry: { scrapeAll() },
                    secondaryTitle: "Edit Manually",
                    onSecondary: { dismissStatusCard() },
                    onDismiss: phase.isSearching ? nil : { dismissStatusCard() })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if deadEnd && !scraping {
                    ScrapeRetryField(label: "Search by name", placeholder: "Title or product code",
                                     text: $nameQuery, onSubmit: { searchAgain() })
                }
            }

            editStage
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .task { await load() }
        .onDisappear {
            searchTask?.cancel()
            pickTask?.cancel()
        }
    }

    // MARK: - Load / seed

    private func load() async {
        guard !loaded, let scraper else { return }
        // Opening straight into a scrape: show the search state immediately, not after the fetch.
        if mode == .scrape { phase = .searching(nil) }
        do {
            guard let data = try await scraper.sceneEditData(id: sceneID) else {
                loadError = "Scene not found"
                phase = .idle
                return
            }
            title = data.title ?? ""
            date = data.date ?? ""
            details = data.details ?? ""
            urls = data.urls ?? []
            studio = data.studio.map { EntityRef(storedID: $0.id, name: $0.name) }
            performers = (data.performers ?? []).map { EntityRef(storedID: $0.id, name: $0.name) }
            tags = (data.tags ?? []).map { EntityRef(storedID: $0.id, name: $0.name) }
            existingStashIDs = data.stash_ids ?? []
            screenshotPath = data.paths?.screenshot
            fileBasename = data.files?.first?.basename
            loaded = true
            if mode == .scrape { scrapeAll() }
        } catch {
            loadError = message(error)
            phase = .idle
        }
    }

    /// Any scraped-but-uncreated entities on the form (dashed chips) — drives the explanatory caption.
    private var hasUnmatched: Bool {
        (studio.map { $0.storedID == nil } ?? false)
            || performers.contains { $0.storedID == nil }
            || tags.contains { $0.storedID == nil }
    }

    /// The current cover to preview: a scraped override, else the scene's screenshot (apikey appended
    /// the same way every other media URL in the app builds it).
    private var coverSource: String? {
        if let coverOverride { return coverOverride }
        guard let screenshotPath, var comps = URLComponents(string: screenshotPath) else { return nil }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "apikey" }
        items.append(URLQueryItem(name: "apikey", value: appState.client?.apiKey ?? ""))
        comps.queryItems = items
        return comps.url?.absoluteString
    }

    // MARK: - Edit stage

    @ViewBuilder private var editStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                coverAndTitle

                VStack(alignment: .leading, spacing: 5) {
                    Text("Date").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    SourceConflictChips(options: dateOptions, text: $date)
                    TextField("YYYY-MM-DD", text: $date)
                        .font(.subheadline)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .capsuleField(foreground: themeManager.current.foregroundColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Details").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    SourceConflictChips(options: detailsOptions, text: $details)
                    TextEditor(text: $details)
                        .font(.subheadline)
                        .frame(minHeight: 64, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(themeManager.current.foregroundColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                studioSection

                entitySection("Performers", refs: performers, emptyText: "No performers") { ref in
                    performers.removeAll { $0.id == ref.id }
                } onCreate: { ref in
                    createPerformer(ref)
                }

                tagSection

                if hasUnmatched {
                    Text("Dashed chips aren't in your library yet — tap one to create it. Anything left dashed is skipped on save.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                scrapeButton

                if !nameHits.isEmpty && !pickerOpen && !scraping {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { pickerOpen = true }
                    } label: {
                        Label("Other matches (\(nameHits.count))", systemImage: "list.bullet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(themeManager.current.foregroundColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(themeManager.current.foregroundColor.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if let saveError { SheetErrorLine(message: saveError) }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var coverAndTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ScrapedImageView(source: coverSource)
                    .frame(width: 118, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if coverOverride != nil {
                            Text("new")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(themeManager.current.accentColor, in: Capsule())
                                .padding(3)
                        }
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Title").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    SourceConflictChips(options: titleOptions, text: $title)
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(1...3)
                        .capsuleField(foreground: themeManager.current.foregroundColor)
                }
            }
            // Cover chooser: pick which source's poster (or keep the current one). Only after a scrape.
            if !coverOptions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        coverChip(label: "Current", value: nil)
                        ForEach(coverOptions) { option in
                            coverChip(label: option.source, value: option.value)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func coverChip(label: String, value: String?) -> some View {
        let active = coverOverride == value
        return Button {
            coverOverride = value
        } label: {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? .white : themeManager.current.foregroundColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? themeManager.current.accentColor
                                   : themeManager.current.foregroundColor.opacity(0.10),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var studioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Studio").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if studioOptions.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(studioOptions) { option in
                            let active = studio?.name.caseInsensitiveCompare(option.name) == .orderedSame
                            Button {
                                studio = EntityRef(storedID: option.storedID, name: option.name)
                            } label: {
                                Text(option.source)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(active ? .white : themeManager.current.foregroundColor)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(active ? themeManager.current.accentColor
                                                       : themeManager.current.foregroundColor.opacity(0.10),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let studio {
                FlowLayout(spacing: 6) {
                    MetaChip(
                        name: studio.name,
                        matched: studio.storedID != nil,
                        onCreate: { createStudio(studio) },
                        onRemove: { self.studio = nil }
                    )
                }
            } else {
                Text("No studio").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// Chips row for an entity list (performers). Unmatched (dashed, +) chips create the entity when tapped.
    private func entitySection(_ label: String, refs: [EntityRef], emptyText: String,
                               onRemove: @escaping (EntityRef) -> Void,
                               onCreate: @escaping (EntityRef) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if refs.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(refs) { ref in
                        MetaChip(
                            name: ref.name,
                            matched: ref.storedID != nil,
                            onCreate: { onCreate(ref) },
                            onRemove: { onRemove(ref) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags) { ref in
                        MetaChip(
                            name: ref.name,
                            matched: ref.storedID != nil,
                            onCreate: { createTag(ref) },
                            onRemove: { tags.removeAll { $0.id == ref.id } }
                        )
                    }
                }
            }
            TextField("Add tag…", text: $tagSearch)
                .font(.caption)
                .autocorrectionDisabled()
                .capsuleField(foreground: themeManager.current.foregroundColor)
                .task(id: tagSearch) {
                    let q = tagSearch.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { tagResults = []; return }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let client = appState.client else { return }
                    tagResults = (try? await client.findTags(query: q, limit: 12)) ?? []
                }
            if !tagResults.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tagResults.filter { tag in !tags.contains { $0.storedID == tag.id } }) { tag in
                        Button {
                            tags.append(EntityRef(storedID: tag.id, name: tag.name))
                            tagSearch = ""
                            tagResults = []
                        } label: {
                            Text(tag.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(themeManager.current.foregroundColor.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var scrapeButton: some View {
        Button {
            scrapeAll()
        } label: {
            HStack(spacing: 8) {
                if scraping { ProgressView().controlSize(.small) }
                Label(scraping ? "Searching…" : "Scrape Metadata",
                      systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(themeManager.current.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(themeManager.current.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(scraping)
    }

    // MARK: - Scrape all sources + merge

    /// Phase changes always animate, so the pinned status card glides in/out and its bar fills smoothly.
    private func setPhase(_ new: ScrapePhase) {
        withAnimation(.smooth(duration: 0.3)) { phase = new }
    }

    private func dismissStatusCard() { setPhase(.idle) }

    /// The two outcomes that leave nothing on the form — where the by-name search field belongs.
    private var deadEnd: Bool {
        switch phase {
        case .nothingFound, .failed: return true
        default: return false
        }
    }

    private var statusHint: String {
        let base = "Fingerprint matching only finds the exact same file that was submitted to these databases — re-encoded, trimmed or re-muxed copies often have no match."
        if nameScrapers.isEmpty {
            return base + " Your Stash server has no community scrapers installed that can search by name — add some under Settings → Metadata Providers. You can still fill in the details by hand."
        }
        return base + " The name search tried each installed community scraper in turn; edit the search term and try again, or fill in the details by hand."
    }

    /// Stage 1: stash-box fingerprint pass (all three at once). Stage 2, only when that finds nothing:
    /// the ranked by-name pass over the server's community scrapers.
    private func scrapeAll() {
        guard let scraper, !scraping else { return }
        scraping = true
        resetNameSearch()
        nameQuery = StashScraper.nameQuery(title: title, fileBasename: fileBasename)
        fingerprintProgress = nil
        setPhase(.searching(nil))
        searchTask = Task {
            defer { scraping = false }
            do {
                let result = try await scraper.scrapeSceneEverywhere(sceneID: sceneID) { progress in
                    setPhase(.searching(progress))
                }
                if !result.items.isEmpty { applyMerged(result.items) }
                // A find, or every stash-box unreachable (the server itself is down, so a name search
                // would only fail the same way) ends here; otherwise go on to the name search.
                if !result.items.isEmpty || result.progress.unreachable.count == result.progress.total {
                    setPhase(.finished(result.progress, matched: !result.items.isEmpty, how: Self.fingerprintHow))
                    return
                }
                fingerprintProgress = result.progress
            } catch is StashScraper.NoSourcesError {
                fingerprintProgress = nil               // no stash-box configured — community scrapers may still work
            } catch {
                setPhase(.thrown(error))
                return
            }
            await beginNameSearch()
        }
    }

    /// Search again by the (possibly edited) term, from the first ranked scraper.
    private func searchAgain() {
        guard !scraping, resolvingHit == nil,
              !nameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scraping = true
        resetNameSearch()
        setPhase(.searching(nil))
        searchTask = Task {
            defer { scraping = false }
            await beginNameSearch()
        }
    }

    /// "Keep searching": carry on down the ranked list from where the last pass stopped.
    private func keepSearching() {
        guard !scraping, resolvingHit == nil else { return }
        scraping = true
        pickerOpen = false
        searchTask = Task {
            defer { scraping = false }
            await runNameSearch()
        }
    }

    private var nameHow: String {
        let q = "by name “\(nameQuery.trimmingCharacters(in: .whitespacesAndNewlines))”"
        return fingerprintProgress == nil ? q : "by file fingerprint and " + q
    }

    /// List the installed NAME scrapers (ranked), queue them behind the fingerprint rows, and start.
    private func beginNameSearch() async {
        guard let scraper else { return }
        do {
            let sources = try await scraper.nameSceneSources()
            guard !Task.isCancelled else { return }
            nameScrapers = sources
            nameCursor = 0
            nameProgress = (fingerprintProgress ?? StashScraper.ScrapeProgress(sources: [])).appendingPending(sources)
            let blank = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if sources.isEmpty || blank {
                if let fingerprintProgress {
                    setPhase(.finished(fingerprintProgress, matched: false, how: Self.fingerprintHow))
                } else {
                    setPhase(.thrown(StashScraper.NoSourcesError()))
                }
                return
            }
            await runNameSearch()
        } catch {
            setPhase(.thrown(error))
        }
    }

    /// One leg of the ranked pass: sequential, stops at the first scraper with candidates.
    private func runNameSearch() async {
        guard let scraper, let progress = nameProgress else { return }
        let query = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        setPhase(.searching(progress))
        let run = await scraper.searchScenesByName(
            query: query, scrapers: nameScrapers, start: nameCursor, progress: progress
        ) { update in
            nameProgress = update
            setPhase(.searching(update))
        }
        guard !Task.isCancelled else { return }
        nameProgress = run.progress
        nameCursor = run.nextIndex
        if !run.hits.isEmpty {
            nameHits += run.hits
            withAnimation(.smooth(duration: 0.3)) { pickerOpen = true }
            setPhase(.idle)
        } else if !nameHits.isEmpty {
            withAnimation(.smooth(duration: 0.3)) { pickerOpen = true }     // "keep searching" ran dry
            setPhase(.idle)
        } else if run.progress.noMatch.isEmpty {
            setPhase(.finished(run.progress, matched: false, how: nameHow))  // nothing even answered
        } else {
            // Individual scrapers failing is routine (sites down, blocked) — the rows show which; the
            // verdict is still "nothing found" as long as some source was actually reached.
            setPhase(.nothingFound(how: nameHow, progress: run.progress))
        }
    }

    /// Pick a candidate: complete it the way Stash's own UI does (second fetch), then fill the form.
    /// The form is snapshotted before the FIRST pick and restored before each later one, so switching
    /// candidates replaces — rather than unions with — the previous one.
    private func choose(_ index: Int) {
        guard let scraper, resolvingHit == nil, nameHits.indices.contains(index) else { return }
        let hit = nameHits[index]
        resolvingHit = index
        pickTask = Task {
            defer { resolvingHit = nil }
            var full = hit.scene
            var note: String?
            do {
                full = try await scraper.sceneDetail(source: hit.source, candidate: hit.scene)
            } catch {
                note = "Couldn't fetch full details from \(hit.source.name) — filled in what the search result had."
            }
            guard !Task.isCancelled else { return }
            if let baseline { restore(baseline) } else { baseline = snapshot() }
            applyMerged([StashScraper.SourcedScene(source: hit.source, scene: full)])
            loadError = note
            withAnimation(.smooth(duration: 0.3)) { pickerOpen = false }
            setPhase(.found(sources: [hit.source.name], unreachable: []))
        }
    }

    /// Drop any previous search's candidates (and undo a picked one) before a fresh search.
    private func resetNameSearch() {
        if let baseline { restore(baseline) }
        baseline = nil
        nameHits = []
        pickerOpen = false
        loadError = nil
    }

    private func snapshot() -> FormSnapshot {
        FormSnapshot(title: title, date: date, details: details, urls: urls, studio: studio,
                     performers: performers, tags: tags, coverOverride: coverOverride,
                     pendingStashIDs: pendingStashIDs)
    }

    private func restore(_ s: FormSnapshot) {
        title = s.title; date = s.date; details = s.details; urls = s.urls; studio = s.studio
        performers = s.performers; tags = s.tags; coverOverride = s.coverOverride
        pendingStashIDs = s.pendingStashIDs
        titleOptions = []; dateOptions = []; detailsOptions = []; studioOptions = []; coverOptions = []
    }

    /// Build per-field conflict options and union entities from every source's result. Sources arrive
    /// priority-ordered, so the first distinct value (the default) is the highest-priority source's.
    private func applyMerged(_ sourced: [StashScraper.SourcedScene]) {
        // Scalars: distinct source-labeled values, plus the current value as a "Current" fallback so
        // scraping never silently discards what was there.
        titleOptions = SourcedValue.distinct(
            sourced.map { ($0.source.name, $0.scene.title) } + [("Current", title.isEmpty ? nil : title)])
        if let first = titleOptions.first { title = first.value }

        dateOptions = SourcedValue.distinct(
            sourced.map { ($0.source.name, $0.scene.date) } + [("Current", date.isEmpty ? nil : date)])
        if let first = dateOptions.first { date = first.value }

        detailsOptions = SourcedValue.distinct(
            sourced.map { ($0.source.name, $0.scene.details) } + [("Current", details.isEmpty ? nil : details)])
        if let first = detailsOptions.first { details = first.value }

        // Cover: scraped posters only (default to the top source's); "Current" chip keeps the existing one.
        coverOptions = SourcedValue.distinct(sourced.map { ($0.source.name, $0.scene.image) })
        coverOverride = coverOptions.first?.value

        // Studio: distinct by name, priority-first, carrying a matched local id when any source had one.
        studioOptions = mergedStudios(sourced)
        if let first = studioOptions.first {
            studio = EntityRef(storedID: first.storedID, name: first.name)
        }

        // Tags + performers: union across ALL sources (deduped), added onto whatever was already there.
        for item in sourced { mergeEntities(from: item.scene) }

        // Stash-box linkages: one per stash-box source that matched.
        var stashIDs = existingStashIDs
        for item in sourced {
            if case .stashBox(let endpoint) = item.source.kind,
               let remoteID = item.scene.remote_site_id, !remoteID.isEmpty {
                stashIDs.removeAll { $0.endpoint.caseInsensitiveCompare(endpoint) == .orderedSame }
                stashIDs.append(StashScraper.StashIDPair(endpoint: endpoint, stash_id: remoteID))
            }
        }
        pendingStashIDs = stashIDs == existingStashIDs ? nil : stashIDs
    }

    /// Distinct studios across sources (+ the current studio), priority-first, sources that agree joined.
    private func mergedStudios(_ sourced: [StashScraper.SourcedScene]) -> [StudioOption] {
        struct Acc { var sources: [String]; var storedID: String?; let display: String }
        var order: [String] = []
        var accs: [String: Acc] = [:]
        func add(source: String, name: String?, id: String?) {
            let clean = (name ?? "").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return }
            let key = clean.lowercased()
            if var existing = accs[key] {
                existing.sources.append(source)
                if existing.storedID == nil { existing.storedID = id }   // prefer a matched local id
                accs[key] = existing
            } else {
                accs[key] = Acc(sources: [source], storedID: id, display: clean)
                order.append(key)
            }
        }
        for item in sourced {
            add(source: item.source.name, name: item.scene.studio?.name, id: item.scene.studio?.stored_id)
        }
        if let studio { add(source: "Current", name: studio.name, id: studio.storedID) }
        return order.map { key in
            let acc = accs[key]!
            return StudioOption(source: acc.sources.joined(separator: " · "), storedID: acc.storedID, name: acc.display)
        }
    }

    /// Union a scraped scene's tags + performers onto the form (matched by stored_id, then by name).
    private func mergeEntities(from scene: StashScraper.ScrapedSceneData) {
        for scraped in scene.performers ?? [] {
            guard let name = scraped.name, !name.isEmpty else { continue }
            if let sid = scraped.stored_id {
                if !performers.contains(where: { $0.storedID == sid }) {
                    performers.append(EntityRef(storedID: sid, name: name))
                }
            } else if !performers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                performers.append(EntityRef(storedID: nil, name: name, scrapedPerformer: scraped))
            }
        }
        for scraped in scene.tags ?? [] {
            if let sid = scraped.stored_id {
                if !tags.contains(where: { $0.storedID == sid }) {
                    tags.append(EntityRef(storedID: sid, name: scraped.name))
                }
            } else if !tags.contains(where: { $0.name.caseInsensitiveCompare(scraped.name) == .orderedSame }) {
                tags.append(EntityRef(storedID: nil, name: scraped.name))
            }
        }
        if let u = scene.urls, !u.isEmpty { urls = Array(Set(urls).union(u)).sorted() }
    }

    // MARK: - Create-missing entities (tap on a dashed chip)

    private func createTag(_ ref: EntityRef) {
        guard let scraper, ref.storedID == nil else { return }
        Task {
            do {
                let id = try await scraper.createTag(name: ref.name)
                if let i = tags.firstIndex(where: { $0.id == ref.id }) { tags[i].storedID = id }
            } catch { saveError = message(error) }
        }
    }

    private func createStudio(_ ref: EntityRef) {
        guard let scraper, ref.storedID == nil else { return }
        Task {
            do {
                let id = try await scraper.createStudio(name: ref.name)
                if studio?.id == ref.id { studio?.storedID = id }
            } catch { saveError = message(error) }
        }
    }

    private func createPerformer(_ ref: EntityRef) {
        guard let scraper, ref.storedID == nil else { return }
        Task {
            do {
                let id: String
                if let scraped = ref.scrapedPerformer {
                    id = try await scraper.createPerformer(PerformerDraft(scraped: scraped).createInput(
                        stashIDs: nil, image: scraped.images?.first))
                } else {
                    id = try await scraper.createPerformer(StashScraper.PerformerCreate(name: ref.name))
                }
                if let i = performers.firstIndex(where: { $0.id == ref.id }) { performers[i].storedID = id }
            } catch { saveError = message(error) }
        }
    }

    // MARK: - Save

    private func save() {
        guard let scraper, loaded, !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            var edit = StashScraper.SceneEdit(id: sceneID)
            edit.title = title
            edit.details = details
            // An empty date is OMITTED (= unchanged), not sent: Stash rejects "" as an invalid date.
            let trimmedDate = date.trimmingCharacters(in: .whitespaces)
            edit.date = trimmedDate.isEmpty ? nil : trimmedDate
            edit.urls = urls
            edit.studio_id = studio?.storedID          // uncreated (dashed) studio is skipped
            edit.performer_ids = performers.compactMap(\.storedID)
            edit.tag_ids = tags.compactMap(\.storedID)
            edit.cover_image = coverOverride
            edit.stash_ids = pendingStashIDs
            do {
                try await scraper.updateScene(edit)
                // Refetch here (inside the same task that just saved) and hand the fresh scene back so the
                // detail screen updates instantly, with no dependence on a parent-side round trip.
                let fresh = await refetchScene()
                onSaved(fresh)
                dismiss()
            } catch {
                saveError = message(error)
            }
        }
    }

    private func refetchScene() async -> StashScene? {
        guard let client = appState.client else { return nil }
        return try? await client.findScene(id: sceneID)
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
