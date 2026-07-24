import SwiftUI

// Shared building blocks for the metadata scrape/edit sheets (scene + performer + create-performer).
// All transient sheet UI — nothing here runs while browsing or playing, so it has zero cost on the
// scroll/playback paths.

/// Renders a scraped image string, which per the Stash schema is either a base64 **data URL**
/// (`data:image/jpeg;base64,…` — the server already fetched the remote file) or a plain http(s) URL.
/// Data URLs are decoded off the main actor; URLs go through the app's ImageCache (downsampled).
struct ScrapedImageView: View {
    let source: String?
    var maxPixel: CGFloat = 600
    @Environment(\.imageCache) private var imageCache
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: source) {
            image = nil
            guard let source, !source.isEmpty else { return }
            if source.hasPrefix("data:") {
                // "data:image/jpeg;base64,XXXX" → decode + pre-rasterize off-main.
                let decoded = await Task.detached(priority: .userInitiated) { () async -> UIImage? in
                    guard let comma = source.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(source[source.index(after: comma)...]),
                                          options: .ignoreUnknownCharacters)
                    else { return nil }
                    guard let img = UIImage(data: data) else { return nil }
                    return await img.byPreparingForDisplay() ?? img
                }.value
                guard !Task.isCancelled else { return }
                image = decoded
            } else if let url = URL(string: source) {
                image = try? await imageCache.image(for: url, maxPixel: maxPixel)
            }
        }
    }
}

/// Compact, scrollable source picker — stash-boxes first, then scrapers (the list Stash's own UI
/// shows). Bounded height so a long scraper list never swallows the sheet; tap = choose and go.
struct ScrapeSourceList: View {
    let sources: [StashScraper.Source]
    let busySourceID: String?
    var onPick: (StashScraper.Source) -> Void
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(sources) { source in
                    Button {
                        onPick(source)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: source.isStashBox ? "shippingbox.fill" : "puzzlepiece.extension.fill")
                                .font(.caption)
                                .foregroundStyle(source.isStashBox ? themeManager.current.accentColor : .secondary)
                                .frame(width: 20)
                            Text(source.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(themeManager.current.foregroundColor)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if busySourceID == source.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(themeManager.current.foregroundColor.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busySourceID != nil)
                }
            }
        }
        .frame(maxHeight: 230)
        .scrollIndicators(.hidden)
    }
}

/// A small entity chip (tag / performer) for the edit sheets. `matched: false` = scraped but not in
/// the library (greyed, dashed) — tapping runs `onCreate` when provided; a trailing × removes it.
struct MetaChip: View {
    let name: String
    var matched = true
    var onCreate: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 5) {
            if !matched {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            Text(name)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(matched ? themeManager.current.foregroundColor : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            themeManager.current.foregroundColor.opacity(matched ? 0.12 : 0.05),
            in: Capsule()
        )
        .overlay {
            if !matched {
                Capsule().strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Capsule())
        .onTapGesture { if !matched { onCreate?() } }
    }
}

/// One labeled text field row for the edit sheets — caption label above a capsule field, matching the
/// filter panel's field styling.
struct EditFieldRow: View {
    let label: String
    var placeholder = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(keyboard == .default ? .words : .never)
                .capsuleField(foreground: themeManager.current.foregroundColor)
        }
    }
}

/// Sheet chrome: Cancel / title / trailing action on one row. Kept custom (not a NavigationStack
/// toolbar) so the sheet stays lightweight at the medium detent.
struct SheetHeader: View {
    let title: String
    var actionTitle: String? = nil
    var actionDisabled = false
    var busy = false
    var onCancel: () -> Void
    var onAction: (() -> Void)? = nil
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .foregroundStyle(themeManager.current.foregroundColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
                    .frame(minWidth: 44, alignment: .trailing)
            } else if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(actionDisabled ? Color.secondary : themeManager.current.accentColor)
                    .disabled(actionDisabled)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
    }
}

/// Inline error line for the sheets — the same never-swallow-silently rule as the jobs panel.
struct SheetErrorLine: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
