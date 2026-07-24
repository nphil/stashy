import SwiftUI

/// Add-performer flow (the + button on the Performers screen), mirroring Stash's workflow: type a
/// name → pick a scrape source → search → tap the right match → review the pre-filled form and pick
/// the photo you want → Create. A manual path ("create without scraping") covers performers no
/// scraper knows.
struct PerformerCreateSheet: View {
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case search, results, form }

    @State private var stage: Stage = .search
    @State private var name = ""
    @State private var sources: [StashScraper.Source] = []
    @State private var sourcesError: String?
    @State private var busySourceID: String?
    @State private var results: [StashScraper.ScrapedPerformerData] = []
    @State private var resultsSource: StashScraper.Source?
    @State private var applyingResultID: String?
    @State private var searchError: String?

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
        .task { await loadSources() }
    }

    private func loadSources() async {
        guard sources.isEmpty, let scraper else { return }
        do {
            sources = try await scraper.performerSources()
        } catch {
            sourcesError = message(error)
        }
    }

    // MARK: - Search stage

    @ViewBuilder private var searchStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EditFieldRow(label: "Performer name", placeholder: "Name", text: $name)
                    .onSubmit { if let first = sources.first { search(with: first) } }

                if let searchError {
                    SheetErrorLine(message: searchError)
                }
                if let sourcesError {
                    SheetErrorLine(message: sourcesError)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Search with")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if sources.isEmpty && sourcesError == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading sources…").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        ScrapeSourceList(sources: sources, busySourceID: busySourceID) { source in
                            search(with: source)
                        }
                    }
                }

                // Manual path for performers no scraper knows — straight to the empty form.
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

    private func search(with source: StashScraper.Source) {
        guard let scraper, busySourceID == nil else { return }
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { searchError = "Type a name to search for."; return }
        busySourceID = source.id
        searchError = nil
        Task {
            defer { busySourceID = nil }
            do {
                let found = try await scraper.searchPerformers(source: source, name: query)
                if found.isEmpty {
                    searchError = "\(source.name) found no match for “\(query)”."
                    return
                }
                results = found
                resultsSource = source
                stage = .results
            } catch {
                searchError = message(error)
            }
        }
    }

    // MARK: - Results stage

    @ViewBuilder private var resultsStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(results.count) matches from \(resultsSource?.name ?? "scraper") — pick the right one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(results) { result in
                        Button {
                            pick(result)
                        } label: {
                            PerformerResultRow(result: result, busy: applyingResultID == result.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingResultID != nil)
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

    private func pick(_ candidate: StashScraper.ScrapedPerformerData) {
        guard let scraper, let source = resultsSource, applyingResultID == nil else { return }
        applyingResultID = candidate.id
        Task {
            defer { applyingResultID = nil }
            do {
                let full = try await scraper.performerDetail(source: source, candidate: candidate)
                draft = PerformerDraft(scraped: full)
                if draft.name.isEmpty { draft.name = name.trimmingCharacters(in: .whitespaces) }
                scrapedImages = full.images ?? []
                selectedImage = scrapedImages.first     // Stash's default: images[0]; picker overrides
                if case .stashBox(let endpoint) = source.kind {
                    pendingStashIDs = StashScraper.mergedStashIDs(
                        existing: nil, endpoint: endpoint, remoteID: full.remote_site_id)
                }
                stage = .form
            } catch {
                searchError = message(error)
            }
        }
    }

    // MARK: - Form stage

    @ViewBuilder private var formStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !scrapedImages.isEmpty {
                    ScrapedImagePicker(images: scrapedImages, selected: $selectedImage)
                }

                PerformerFormFields(draft: $draft)

                if let createError {
                    SheetErrorLine(message: createError)
                }

                Button {
                    stage = results.isEmpty ? .search : .results
                } label: {
                    Label("Back to results", systemImage: "chevron.left")
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
