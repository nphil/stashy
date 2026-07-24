import SwiftUI

/// Add-performer flow (the + button on the Performers screen), mirroring Stash: type a name → search
/// **all three sources (StashDB / ThePornDB / FansDB) at once** → pick the right person from a merged
/// list (same person across sources collapses into one row) → review the pre-filled form, pick or
/// upload the photo → Create. A manual path covers performers no source knows.
struct PerformerCreateSheet: View {
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case search, results, form }

    @State private var stage: Stage = .search
    @State private var name = ""
    @State private var candidates: [StashScraper.MergedPerformerCandidate] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var applyingID: String?

    @State private var draft = PerformerDraft()
    @State private var scrapedImages: [String] = []
    @State private var selectedImage: String?
    @State private var pendingStashIDs: [StashScraper.StashIDPair]?

    @State private var creating = false
    @State private var createError: String?

    private var scraper: StashScraper? {
        appState.client.map { StashScraper(client: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: stage == .form ? "New Performer" : "Add Performer",
                actionTitle: stage == .form ? "Create" : nil,
                actionDisabled: draft.name.trimmingCharacters(in: .whitespaces).isEmpty || creating,
                busy: creating,
                onCancel: { dismiss() },
                onAction: { create() }
            )

            switch stage {
            case .search: searchStage
            case .results: resultsStage
            case .form: formStage
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Search stage

    @ViewBuilder private var searchStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EditFieldRow(label: "Performer name", placeholder: "Name", text: $name)
                    .onSubmit { searchAll() }

                if let searchError { SheetErrorLine(message: searchError) }

                Button {
                    searchAll()
                } label: {
                    HStack(spacing: 8) {
                        if searching { ProgressView().controlSize(.small) }
                        Label(searching ? "Searching StashDB · ThePornDB · FansDB…" : "Search",
                              systemImage: "sparkle.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(themeManager.current.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(themeManager.current.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(searching || name.trimmingCharacters(in: .whitespaces).isEmpty)

                // Manual path for performers no source knows — straight to the empty form.
                Button {
                    draft = PerformerDraft()
                    draft.name = name.trimmingCharacters(in: .whitespaces)
                    scrapedImages = []
                    selectedImage = nil
                    pendingStashIDs = nil
                    stage = .form
                } label: {
                    Label("Create manually without scraping", systemImage: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func searchAll() {
        guard let scraper, !searching else { return }
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { searchError = "Type a name to search for."; return }
        searching = true
        searchError = nil
        Task {
            defer { searching = false }
            do {
                let result = try await scraper.searchPerformersEverywhere(name: query)
                let grouped = StashScraper.groupPerformers(result.items)
                guard !grouped.isEmpty else {
                    searchError = result.failed.isEmpty
                        ? "No match found on StashDB, ThePornDB or FansDB for “\(query)”."
                        : "Couldn't reach \(StashScraper.sourceList(result.failed)) — check they're online and try again."
                    return
                }
                candidates = grouped
                searchError = result.failed.isEmpty ? nil
                    : "\(StashScraper.sourceList(result.failed)) \(result.failed.count == 1 ? "was" : "were") unreachable — showing the rest."
                stage = .results
            } catch {
                searchError = message(error)
            }
        }
    }

    // MARK: - Results stage

    @ViewBuilder private var resultsStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(candidates.count) \(candidates.count == 1 ? "match" : "matches") — pick the right person.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let searchError { SheetErrorLine(message: searchError) }
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
                stage = .search
            } label: {
                Label("Back to search", systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func pick(_ candidate: StashScraper.MergedPerformerCandidate) {
        guard let scraper, applyingID == nil else { return }
        applyingID = candidate.id
        Task {
            defer { applyingID = nil }
            let resolved = await scraper.resolvePerformer(candidate)
            var merged = PerformerDraft()
            merged.name = name.trimmingCharacters(in: .whitespaces)
            for scraped in resolved.ordered.reversed() { merged.merge(scraped: scraped) }
            if merged.name.isEmpty { merged.name = name.trimmingCharacters(in: .whitespaces) }
            draft = merged
            scrapedImages = resolved.images
            selectedImage = resolved.images.first      // Stash's default: images[0]; picker/upload overrides
            pendingStashIDs = resolved.stashIDs.isEmpty ? nil : resolved.stashIDs
            stage = .form
        }
    }

    // MARK: - Form stage

    @ViewBuilder private var formStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PerformerPhotoPicker(images: $scrapedImages, selected: $selectedImage)

                PerformerFormFields(draft: $draft)

                if let createError { SheetErrorLine(message: createError) }

                Button {
                    stage = candidates.isEmpty ? .search : .results
                } label: {
                    Label(candidates.isEmpty ? "Back to search" : "Back to results", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func create() {
        guard let scraper, !creating else { return }
        creating = true
        createError = nil
        Task {
            defer { creating = false }
            do {
                _ = try await scraper.createPerformer(
                    draft.createInput(stashIDs: pendingStashIDs, image: selectedImage))
                onCreated()
                dismiss()
            } catch {
                createError = message(error)
            }
        }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
