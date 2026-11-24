import SwiftUI

/// The results card of a by-name scene search: every candidate the community scraper returned (cover,
/// title, studio · date), tap one to fill the edit form with it. Footer: an editable search term +
/// Search, and "Keep searching" to carry on down the ranked scraper list. Pinned above the form like
/// `ScrapeStatusCard`, so it reads as the next step of the same search.
struct SceneCandidatePicker: View {
    let hits: [StashScraper.SourcedScene]
    /// Row currently being completed (second fetch); the whole list is inert meanwhile.
    let resolving: Int?
    /// How many ranked scrapers are still untried; 0 hides "Keep searching".
    let remaining: Int
    @Binding var query: String
    let onPick: (Int) -> Void
    let onKeepSearching: () -> Void
    let onSearch: () -> Void
    let onDismiss: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    private var accent: Color { themeManager.current.accentColor }
    private var fg: Color { themeManager.current.foregroundColor }

    private var sourceNames: String {
        var seen: [String] = []
        for hit in hits where !seen.contains(hit.source.name) { seen.append(hit.source.name) }
        return StashScraper.sourceList(seen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(hits.count) possible \(hits.count == 1 ? "match" : "matches") on \(sourceNames)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            Text("Tap the one that is this scene — its details fill the form below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(hits.enumerated()), id: \.offset) { index, hit in
                        row(index: index, hit: hit)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 230)

            ScrapeRetryField(label: "Search term", placeholder: "Title or product code",
                             text: $query, disabled: resolving != nil, onSubmit: onSearch)

            if remaining > 0 {
                Button(action: onKeepSearching) {
                    Label("Keep searching · \(remaining) more \(remaining == 1 ? "source" : "sources")",
                          systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(fg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(fg.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(resolving != nil)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.28), lineWidth: 1)
        }
    }

    private func row(index: Int, hit: StashScraper.SourcedScene) -> some View {
        let scene = hit.scene
        let meta = [hit.source.name, scene.studio?.name, scene.date]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Button { onPick(index) } label: {
            HStack(spacing: 10) {
                ScrapedImageView(source: scene.image, maxPixel: 240)
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title ?? "Untitled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(fg)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if resolving == index {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(6)
            .background(fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolving != nil)
    }
}
