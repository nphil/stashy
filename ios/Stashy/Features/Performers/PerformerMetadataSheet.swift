import SwiftUI

/// How the performer metadata sheet opens from the ••• menu.
enum PerformerMetadataMode: String, Identifiable {
    case edit, scrape
    var id: String { rawValue }
}

/// Performer metadata "mini window" — the same medium-detent glass sheet pattern as the scene one.
/// EDIT stage = the full performer form (seeded from a fresh server fetch, richer than the app's list
/// model). SCRAPE stage = pick a source → results for the performer's name → tapping a result pulls
/// full detail (stash-box results are already complete; classic scrapers re-scrape the selected
/// fragment, like Stash's UI) and merges it into the form, including a photo picker over the scraped
/// images. Nothing is written until Save.
struct PerformerMetadataSheet: View {
    let performerID: String
    let mode: PerformerMetadataMode
    var onSaved: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case edit, sources, results }

    @State private var stage: Stage = .edit
    @State private var loaded = false
    @State private var loadError: String?

    @State private var draft = PerformerDraft()
    @State private var existingStashIDs: [StashScraper.StashIDPair] = []
    @State private var pendingStashIDs: [StashScraper.StashIDPair]?
    @State private var currentImagePath: String?
    @State private var scrapedImages: [String] = []
    @State private var selectedImage: String?

    @State private var sources: [StashScraper.Source] = []
    @State private var busySourceID: String?
    @State private var results: [StashScraper.ScrapedPerformerData] = []
    @State private var resultsSource: StashScraper.Source?
    @State private var scrapeError: String?
    @State private var applyingResultID: String?

    @State private var saving = false
    @State private var saveError: String?

    private var scraper: StashScraper? {
        appState.client.map { StashScraper(client: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: stage == .edit ? "Edit Performer" : (stage == .sources ? "Scrape From" : "Results"),
                actionTitle: stage == .edit ? "Save" : nil,
                actionDisabled: !loaded || saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
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

    private func load() async {
        guard !loaded, let scraper else { return }
        do {
            guard let data = try await scraper.performerEditData(id: performerID) else {
                loadError = "Performer not found"
                return
            }
            draft = PerformerDraft(data: data)
            existingStashIDs = data.stash_ids ?? []
            currentImagePath = data.image_path
            loaded = true
            if mode == .scrape { openSources() }
        } catch {
            loadError = message(error)
        }
    }

    // MARK: - Edit stage

    @ViewBuilder private var editStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !scrapedImages.isEmpty {
                    ScrapedImagePicker(images: scrapedImages, selected: $selectedImage)
                }

                PerformerFormFields(draft: $draft)

                Button {
                    openSources()
                } label: {
                    Label("Scrape Metadata…", systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(themeManager.current.accentColor.opacity(0.12), in: Capsule())
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

    // MARK: - Sources stage

    @ViewBuilder private var sourcesStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Searches for “\(draft.name)”. Stash-box accounts first, then name-capable scrapers.")
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
                    search(with: source)
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
                sources = try await scraper.performerSources()
                if sources.isEmpty { scrapeError = "No performer scrapers or stash-box accounts are configured on the server." }
            } catch {
                scrapeError = message(error)
            }
        }
    }

    private func search(with source: StashScraper.Source) {
        guard let scraper, busySourceID == nil else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { scrapeError = "The performer has no name to search for."; return }
        busySourceID = source.id
        scrapeError = nil
        Task {
            defer { busySourceID = nil }
            do {
                let found = try await scraper.searchPerformers(source: source, name: name)
                if found.isEmpty {
                    scrapeError = "\(source.name) found no match for “\(name)”."
                    return
                }
                results = found
                resultsSource = source
                stage = .results
            } catch {
                scrapeError = message(error)
            }
        }
    }

    // MARK: - Results stage

    @ViewBuilder private var resultsStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(results.count) matches from \(resultsSource?.name ?? "scraper") — tap one to merge it into the form.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(results) { result in
                        Button {
                            apply(result)
                        } label: {
                            PerformerResultRow(result: result, busy: applyingResultID == result.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingResultID != nil)
                    }
                }
            }
            .scrollIndicators(.hidden)
            backToEditButton
        }
    }

    private func apply(_ candidate: StashScraper.ScrapedPerformerData) {
        guard let scraper, let source = resultsSource, applyingResultID == nil else { return }
        applyingResultID = candidate.id
        Task {
            defer { applyingResultID = nil }
            do {
                let full = try await scraper.performerDetail(source: source, candidate: candidate)
                draft.merge(scraped: full)
                scrapedImages = full.images ?? []
                if selectedImage == nil { selectedImage = scrapedImages.first }
                if case .stashBox(let endpoint) = source.kind {
                    pendingStashIDs = StashScraper.mergedStashIDs(
                        existing: existingStashIDs, endpoint: endpoint, remoteID: full.remote_site_id)
                }
                stage = .edit
            } catch {
                scrapeError = message(error)
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
            do {
                try await scraper.updatePerformer(draft.updateInput(
                    id: performerID, stashIDs: pendingStashIDs, image: selectedImage))
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

/// One performer search result row: leading photo, name + disambiguation, birthdate · country line.
struct PerformerResultRow: View {
    let result: StashScraper.ScrapedPerformerData
    var busy = false
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 10) {
            ScrapedImageView(source: result.images?.first, maxPixel: 200)
                .frame(width: 44, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(result.name ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .lineLimit(1)
                    if let dis = result.disambiguation, !dis.isEmpty {
                        Text("(\(dis))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if let birth = result.birthdate, !birth.isEmpty { Text(birth) }
                    if let country = result.country, !country.isEmpty { Text(country.countryFlag) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.current.foregroundColor.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
