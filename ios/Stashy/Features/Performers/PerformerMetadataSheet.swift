import SwiftUI

/// How the performer metadata sheet opens from the ••• menu.
enum PerformerMetadataMode: String, Identifiable {
    case edit, scrape
    var id: String { rawValue }
}

/// Performer metadata "mini window" — the same medium-detent glass sheet pattern as the scene one.
/// EDIT stage = the full performer form (seeded from a fresh server fetch). SCRAPE queries **all three
/// configured sources (StashDB / ThePornDB / FansDB) at once** for the performer's name and shows a
/// merged candidate list: the same person reported by several sources collapses into one row (tagged
/// with its sources); different people stay separate so you pick the right one. Choosing a row pulls
/// full detail from every contributing source, merges it (priority order), unions the photos into the
/// picker, and drops you back on the form. Nothing is written until Save.
struct PerformerMetadataSheet: View {
    let performerID: String
    let mode: PerformerMetadataMode
    /// Handed the freshly-refetched performer after a save so the detail screen updates in place.
    var onSaved: (Performer?) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case edit, results }

    @State private var stage: Stage = .edit
    @State private var loaded = false
    @State private var loadError: String?

    @State private var draft = PerformerDraft()
    @State private var existingStashIDs: [StashScraper.StashIDPair] = []
    @State private var pendingStashIDs: [StashScraper.StashIDPair]?
    @State private var scrapedImages: [String] = []
    @State private var selectedImage: String?

    @State private var candidates: [StashScraper.MergedPerformerCandidate] = []
    @State private var searching = false
    @State private var scrapeError: String?
    @State private var applyingID: String?

    @State private var saving = false
    @State private var saveError: String?

    private var scraper: StashScraper? {
        appState.client.map { StashScraper(client: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: stage == .edit ? "Edit Performer" : "Results",
                actionTitle: stage == .edit ? "Save" : nil,
                actionDisabled: !loaded || saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                busy: saving,
                onCancel: { dismiss() },
                onAction: { save() }
            )

            if let loadError { SheetErrorLine(message: loadError) }

            switch stage {
            case .edit: editStage
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
            loaded = true
            if mode == .scrape { searchAll() }
        } catch {
            loadError = message(error)
        }
    }

    // MARK: - Edit stage

    @ViewBuilder private var editStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PerformerPhotoPicker(images: $scrapedImages, selected: $selectedImage)

                PerformerFormFields(draft: $draft)

                scrapeButton

                if let saveError { SheetErrorLine(message: saveError) }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var scrapeButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                searchAll()
            } label: {
                HStack(spacing: 8) {
                    if searching { ProgressView().controlSize(.small) }
                    Label(searching ? "Searching StashDB · ThePornDB · FansDB…" : "Scrape Metadata",
                          systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(themeManager.current.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(themeManager.current.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(searching)

            if let scrapeError, stage == .edit { SheetErrorLine(message: scrapeError) }
        }
    }

    // MARK: - Results stage

    @ViewBuilder private var resultsStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(candidates.count) \(candidates.count == 1 ? "match" : "matches") for “\(draft.name)” — tap the right person to merge their details in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let scrapeError { SheetErrorLine(message: scrapeError) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(candidates) { candidate in
                        Button {
                            pick(candidate)
                        } label: {
                            MergedPerformerRow(candidate: candidate, busy: applyingID == candidate.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingID != nil)
                    }
                }
            }
            .scrollIndicators(.hidden)
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
    }

    // MARK: - Scrape

    private func searchAll() {
        guard let scraper, !searching else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { scrapeError = "The performer has no name to search for."; return }
        searching = true
        scrapeError = nil
        Task {
            defer { searching = false }
            do {
                let result = try await scraper.searchPerformersEverywhere(name: name)
                let grouped = StashScraper.groupPerformers(result.items)
                guard !grouped.isEmpty else {
                    scrapeError = result.failed.isEmpty
                        ? "No match found on StashDB, ThePornDB or FansDB for “\(name)”."
                        : "Couldn't reach \(StashScraper.sourceList(result.failed)) — check they're online and try again."
                    return
                }
                candidates = grouped
                scrapeError = result.failed.isEmpty ? nil
                    : "\(StashScraper.sourceList(result.failed)) \(result.failed.count == 1 ? "was" : "were") unreachable — showing the rest."
                stage = .results
            } catch {
                scrapeError = message(error)
            }
        }
    }

    private func pick(_ candidate: StashScraper.MergedPerformerCandidate) {
        guard let scraper, applyingID == nil else { return }
        applyingID = candidate.id
        Task {
            defer { applyingID = nil }
            let resolved = await scraper.resolvePerformer(candidate)
            // Apply highest-priority last so StashDB wins each non-empty field.
            for scraped in resolved.ordered.reversed() { draft.merge(scraped: scraped) }
            scrapedImages = resolved.images
            if selectedImage == nil { selectedImage = scrapedImages.first }
            var merged = existingStashIDs
            for pair in resolved.stashIDs {
                merged.removeAll { $0.endpoint.caseInsensitiveCompare(pair.endpoint) == .orderedSame }
                merged.append(pair)
            }
            pendingStashIDs = merged == existingStashIDs ? nil : merged
            stage = .edit
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
                let fresh = try? await scraper.findPerformer(id: performerID)
                onSaved(fresh)
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

/// One merged candidate row: leading photo, name + disambiguation, birthdate · country, and a row of
/// source badges (the sources that reported this same person).
struct MergedPerformerRow: View {
    let candidate: StashScraper.MergedPerformerCandidate
    var busy = false
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 10) {
            ScrapedImageView(source: candidate.previewImage, maxPixel: 200)
                .frame(width: 44, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .lineLimit(1)
                    if let dis = candidate.disambiguation, !dis.isEmpty {
                        Text("(\(dis))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if let birth = candidate.birthdate, !birth.isEmpty { Text(birth) }
                    if let country = candidate.country, !country.isEmpty { Text(country.countryFlag) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(candidate.sourceNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(themeManager.current.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(themeManager.current.accentColor.opacity(0.14), in: Capsule())
                    }
                }
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
