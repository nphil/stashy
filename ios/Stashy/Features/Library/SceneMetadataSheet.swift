import SwiftUI

/// How the scene metadata sheet opens from the ••• menu: straight into the edit form, or straight
/// into the scraper picker (results then land in the same form for review before saving).
enum SceneMetadataMode: String, Identifiable {
    case edit, scrape
    var id: String { rawValue }
}

/// The scene metadata "mini window": a medium-detent glass sheet floating over the playing video.
/// One sheet, three stages — the EDIT FORM (title / date / details / studio / performers / tags /
/// cover), the SOURCE picker (stash-boxes + fragment scrapers, compact + scrollable), and the scraped
/// RESULTS list. A scrape result is never applied blind: it merges into the form (Stash's own rules —
/// non-empty scalars win, entities match by `stored_id`, unmatched ones become dashed "+" chips you
/// can tap to create) and nothing touches the server until Save.
struct SceneMetadataSheet: View {
    let sceneID: String
    let mode: SceneMetadataMode
    var onSaved: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case edit, sources, results }

    /// A studio/performer/tag reference in the form. `id` nil = scraped entity not in the library yet
    /// (rendered dashed; tap-to-create fills the id in). Uncreated entries are skipped on Save.
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

    @State private var stage: Stage = .edit
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

    // Scrape state.
    @State private var sources: [StashScraper.Source] = []
    @State private var busySourceID: String?
    @State private var results: [StashScraper.ScrapedSceneData] = []
    @State private var resultsSource: StashScraper.Source?
    @State private var scrapeError: String?

    // Tag add-search.
    @State private var tagSearch = ""
    @State private var tagResults: [Tag] = []

    @State private var saving = false
    @State private var saveError: String?

    private var scraper: StashScraper? {
        appState.client.map { StashScraper(client: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: headerTitle,
                actionTitle: stage == .edit ? "Save" : nil,
                actionDisabled: !loaded || saving,
                busy: saving,
                onCancel: { dismiss() },
                onAction: { save() }
            )

            if let loadError {
                SheetErrorLine(message: loadError)
            }

            switch stage {
            case .edit: editStage
            case .sources: sourcesStage
            case .results: resultsStage
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .task { await load() }
    }

    private var headerTitle: String {
        switch stage {
        case .edit: return "Edit Scene"
        case .sources: return "Scrape From"
        case .results: return "Results"
        }
    }

    // MARK: - Load / seed

    private func load() async {
        guard !loaded, let scraper else { return }
        do {
            guard let data = try await scraper.sceneEditData(id: sceneID) else {
                loadError = "Scene not found"
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
            loaded = true
            if mode == .scrape { openSources() }
        } catch {
            loadError = message(error)
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
                        Text("Title")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Title", text: $title, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(1...3)
                            .capsuleField(foreground: themeManager.current.foregroundColor)
                    }
                }

                EditFieldRow(label: "Date", placeholder: "YYYY-MM-DD", text: $date,
                             keyboard: .numbersAndPunctuation)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Details")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $details)
                        .font(.subheadline)
                        .frame(minHeight: 64, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(themeManager.current.foregroundColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                entitySection("Studio", refs: studio.map { [$0] } ?? [],
                              emptyText: "No studio") { _ in
                    studio = nil
                } onCreate: { ref in
                    createStudio(ref)
                }

                entitySection("Performers", refs: performers,
                              emptyText: "No performers") { ref in
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

                Button {
                    openSources()
                } label: {
                    Label("Scrape Metadata…", systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(themeManager.current.accentColor.opacity(0.12),
                                    in: Capsule())
                }
                .buttonStyle(.plain)

                if let saveError {
                    SheetErrorLine(message: saveError)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Chips row for studio/performers. Unmatched (dashed, +) chips create the entity when tapped.
    private func entitySection(_ label: String, refs: [EntityRef], emptyText: String,
                               onRemove: @escaping (EntityRef) -> Void,
                               onCreate: @escaping (EntityRef) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if refs.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            Text("Tags")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
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

    // MARK: - Sources stage

    @ViewBuilder private var sourcesStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stash-box accounts first, then installed scrapers. Tap one to scrape this scene.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let scrapeError {
                SheetErrorLine(message: scrapeError)
            }
            if sources.isEmpty && scrapeError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading sources…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ScrapeSourceList(sources: sources, busySourceID: busySourceID) { source in
                    scrape(with: source)
                }
            }
            backToEditButton
        }
    }

    private var backToEditButton: some View {
        Button {
            stage = .edit
        } label: {
            Label("Back to editing", systemImage: "chevron.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func openSources() {
        stage = .sources
        scrapeError = nil
        guard sources.isEmpty, let scraper else { return }
        Task {
            do {
                sources = try await scraper.sceneSources()
                if sources.isEmpty { scrapeError = "No scene scrapers or stash-box accounts are configured on the server." }
            } catch {
                scrapeError = message(error)
            }
        }
    }

    private func scrape(with source: StashScraper.Source) {
        guard let scraper, busySourceID == nil else { return }
        busySourceID = source.id
        scrapeError = nil
        Task {
            defer { busySourceID = nil }
            do {
                let found = try await scraper.scrapeScene(source: source, sceneID: sceneID)
                if found.isEmpty {
                    scrapeError = "\(source.name) found no match for this scene."
                    return
                }
                results = found
                resultsSource = source
                if found.count == 1 {
                    apply(found[0], from: source)   // single candidate → straight into the form
                } else {
                    stage = .results
                }
            } catch {
                scrapeError = message(error)
            }
        }
    }

    // MARK: - Results stage

    @ViewBuilder private var resultsStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(results.count) matches from \(resultsSource?.name ?? "scraper") — tap one to review it in the form.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        Button {
                            if let resultsSource { apply(result, from: resultsSource) }
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            backToEditButton
        }
    }

    private func resultRow(_ result: StashScraper.ScrapedSceneData) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ScrapedImageView(source: result.image)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title ?? "Untitled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let date = result.date { Text(date) }
                    if let studio = result.studio?.name { Text("· \(studio)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let names = result.performers?.compactMap(\.name), !names.isEmpty {
                    Text(names.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.current.foregroundColor.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Apply scraped result (Stash's merge rules)

    private func apply(_ result: StashScraper.ScrapedSceneData, from source: StashScraper.Source) {
        // Non-empty scalars overwrite; empty scraped fields never clear what's there.
        if let t = result.title, !t.isEmpty { title = t }
        if let d = result.date, !d.isEmpty { date = d }
        if let d = result.details, !d.isEmpty { details = d }
        if let u = result.urls, !u.isEmpty { urls = Array(Set(urls).union(u)).sorted() }
        if let image = result.image, !image.isEmpty { coverOverride = image }
        if let s = result.studio {
            studio = EntityRef(storedID: s.stored_id, name: s.name)
        }
        // Performers: matched ones join by stored_id; unmatched become dashed create-chips carrying
        // their full scraped record (so tap-to-create fills every field, like Stash's dialog).
        for scraped in result.performers ?? [] {
            guard let name = scraped.name, !name.isEmpty else { continue }
            if let sid = scraped.stored_id {
                if !performers.contains(where: { $0.storedID == sid }) {
                    performers.append(EntityRef(storedID: sid, name: name))
                }
            } else if !performers.contains(where: { $0.storedID == nil && $0.name == name }) {
                performers.append(EntityRef(storedID: nil, name: name, scrapedPerformer: scraped))
            }
        }
        for scraped in result.tags ?? [] {
            if let sid = scraped.stored_id {
                if !tags.contains(where: { $0.storedID == sid }) {
                    tags.append(EntityRef(storedID: sid, name: scraped.name))
                }
            } else if !tags.contains(where: { $0.storedID == nil && $0.name == scraped.name }) {
                tags.append(EntityRef(storedID: nil, name: scraped.name))
            }
        }
        // A stash-box match records its linkage (replacing any older link to the same endpoint).
        if case .stashBox(let endpoint) = source.kind {
            pendingStashIDs = StashScraper.mergedStashIDs(
                existing: existingStashIDs, endpoint: endpoint, remoteID: result.remote_site_id)
        }
        stage = .edit
    }

    // MARK: - Create-missing entities (tap on a dashed chip)

    private func createTag(_ ref: EntityRef) {
        guard let scraper, ref.storedID == nil else { return }
        Task {
            do {
                let id = try await scraper.createTag(name: ref.name)
                if let i = tags.firstIndex(where: { $0.id == ref.id }) { tags[i].storedID = id }
            } catch {
                saveError = message(error)
            }
        }
    }

    private func createStudio(_ ref: EntityRef) {
        guard let scraper, ref.storedID == nil else { return }
        Task {
            do {
                let id = try await scraper.createStudio(name: ref.name)
                if studio?.id == ref.id { studio?.storedID = id }
            } catch {
                saveError = message(error)
            }
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
            } catch {
                saveError = message(error)
            }
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
            // Clearing a date isn't supported here — set it in Stash's UI if ever needed.
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
                onSaved()
                dismiss()
            } catch {
                saveError = message(error)
            }
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
