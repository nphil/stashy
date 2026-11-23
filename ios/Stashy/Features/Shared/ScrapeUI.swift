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
                // Scraped posters/headshots are media like any other, so Privacy Mode covers them too.
                // Names and other scraped TEXT stay readable on purpose: this sheet exists to pick the
                // right match, which is impossible if the thing you are matching on is blurred.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .privacyImageBlur()
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

/// One distinct field value contributed by one or more sources (the sources that agreed on it are joined
/// in `source`). Drives the per-field conflict chips.
struct SourcedValue: Identifiable, Hashable, Sendable {
    let source: String   // e.g. "StashDB" or "StashDB · ThePornDB" when they agree
    let value: String
    var id: String { source + "\u{1}" + value }

    /// Collapse (source, value) pairs into the DISTINCT non-empty values, each labeled with every source
    /// that reported it, preserving first-seen (priority) order. One value → no conflict; several → chips.
    static func distinct(_ pairs: [(String, String?)]) -> [SourcedValue] {
        var order: [String] = []                 // normalized value order
        var sources: [String: [String]] = [:]    // normalized value → contributing sources
        var display: [String: String] = [:]      // normalized value → first display spelling
        for (source, raw) in pairs {
            let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            if display[key] == nil { display[key] = value; order.append(key) }
            sources[key, default: []].append(source)
        }
        return order.map { SourcedValue(source: sources[$0]!.joined(separator: " · "), value: display[$0]!) }
    }
}

/// A row of source chips shown ABOVE a field only when the sources disagreed (more than one distinct
/// value). Tapping a chip sets the bound field to that source's value; the chip matching the current
/// text is highlighted. Agreed / single-source fields show nothing here (silent).
struct SourceConflictChips: View {
    let options: [SourcedValue]
    @Binding var text: String
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        if options.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        let active = option.value.caseInsensitiveCompare(text) == .orderedSame
                        Button {
                            text = option.value
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
    }
}

/// Encode a picked photo as the base64 data URL Stash's `image` field accepts. Downscaled + JPEG-
/// compressed OFF the main actor so a large HEIC/PNG never janks the sheet.
enum ImageUpload {
    static func dataURL(from data: Data, maxDimension: CGFloat = 1200) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let image = UIImage(data: data) else { return nil }
            let scaled = image.downscaled(maxDimension: maxDimension)
            guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
            return "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }.value
    }
}

extension UIImage {
    /// Aspect-fit downscale so the longest edge is at most `maxDimension` (no upscaling).
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: target)) }
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

// MARK: - Scrape status (searching / found / nothing found / failed)

/// Everything a metadata search can be showing, in one value, so the scene, performer and add-performer
/// sheets present a search identically. The two non-success outcomes are deliberately separate cases:
/// `.nothingFound` = every source was reached and none had a match; `.failed` = something went wrong
/// (a source or the server was unreachable, an error was thrown), so "not found" can't be claimed.
enum ScrapePhase: Equatable {
    case idle
    /// `nil` until the source list is known (the first round trip), then one entry per source.
    case searching(StashScraper.ScrapeProgress?)
    case found(sources: [String], unreachable: [String])
    /// `how` completes "Searched …" (e.g. `for “Jane Doe”`, `by this scene's file fingerprints`).
    case nothingFound(how: String, progress: StashScraper.ScrapeProgress)
    case failed(title: String, detail: String, progress: StashScraper.ScrapeProgress?)

    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }

    /// The card is for work-in-progress and dead ends; a successful find is shown by the form / results.
    var showsStatusCard: Bool {
        switch self {
        case .searching, .nothingFound, .failed: return true
        case .idle, .found: return false
        }
    }

    /// Sources that errored in a run that DID find something (nil = all reachable).
    var unreachableAfterFind: [String] {
        if case .found(_, let unreachable) = self { return unreachable }
        return []
    }

    /// Classify a finished multi-source run. `matched` = the caller ended up with usable results.
    static func finished(_ progress: StashScraper.ScrapeProgress, matched: Bool, how: String) -> ScrapePhase {
        if matched { return .found(sources: progress.matched, unreachable: progress.unreachable) }
        let down = progress.unreachable
        if down.isEmpty { return .nothingFound(how: how, progress: progress) }
        if down.count == progress.total {
            return .failed(
                title: "Couldn't reach any source",
                detail: "\(StashScraper.sourceList(down)) didn't answer, so nothing was searched. Check that your Stash server is online and its stash-box connections work, then try again.",
                progress: progress)
        }
        return .failed(
            title: "Couldn't finish searching",
            detail: "No match on \(StashScraper.sourceList(progress.noMatch)), and \(StashScraper.sourceList(down)) \(wasWere(down)) unreachable — so this isn't a confirmed “not found”. Try again in a moment.",
            progress: progress)
    }

    /// Phase for a thrown error (no sources configured, server unreachable, bad response…).
    static func thrown(_ error: Error) -> ScrapePhase {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if error is StashScraper.NoSourcesError {
            return .failed(title: "No sources to search", detail: text, progress: nil)
        }
        return .failed(title: "Couldn't search", detail: text, progress: nil)
    }

    static func wasWere(_ names: [String]) -> String { names.count == 1 ? "was" : "were" }
}

/// The pinned status card for a metadata search. Searching: a determinate bar ("2 of 3 sources") with a
/// live row per source. Nothing found: an unmistakable "No metadata found" naming what was searched and
/// where, with the next actions. Failed: orange and worded as an error, never as "not found".
struct ScrapeStatusCard: View {
    let phase: ScrapePhase
    /// Extra advice under a nothing-found result (why it may have missed, what to try).
    var hint: String? = nil
    var foundDetail = "Review the filled-in details below, then tap Save."
    var retryTitle = "Try Again"
    var onRetry: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @Environment(ThemeManager.self) private var themeManager

    private var accent: Color { themeManager.current.accentColor }
    private var fg: Color { themeManager.current.foregroundColor }

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .searching(let progress):
            searching(progress)
        case .found(let sources, let unreachable):
            found(sources: sources, unreachable: unreachable)
        case .nothingFound(let how, let progress):
            nothingFound(how: how, progress: progress)
        case .failed(let title, let detail, let progress):
            failed(title: title, detail: detail, progress: progress)
        }
    }

    // MARK: States

    private func searching(_ progress: StashScraper.ScrapeProgress?) -> some View {
        card(tint: accent) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching for metadata…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(fg)
                Spacer(minLength: 0)
                if let progress {
                    Text("\(progress.finished) of \(progress.total)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ScrapeBar(
                fraction: progress.map { $0.total == 0 ? 0 : Double($0.finished) / Double($0.total) },
                tint: accent)
            if let progress {
                ForEach(progress.entries) { entry in sourceRow(entry) }
            } else {
                Text("Contacting your Stash server…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func found(sources: [String], unreachable: [String]) -> some View {
        card(tint: .green) {
            headerRow(icon: "checkmark.circle.fill", tint: .green,
                      title: sources.isEmpty ? "Metadata found" : "Found on \(StashScraper.sourceList(sources))")
            Text(foundDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !unreachable.isEmpty {
                Label("\(StashScraper.sourceList(unreachable)) \(ScrapePhase.wasWere(unreachable)) unreachable — showing what the others found.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func nothingFound(how: String, progress: StashScraper.ScrapeProgress) -> some View {
        card(tint: accent) {
            headerRow(icon: "magnifyingglass", tint: accent, title: "No metadata found")
            Text("Searched \(how) on \(StashScraper.sourceList(progress.names)) — none of them has a match.")
                .font(.caption)
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(progress.entries) { entry in sourceRow(entry) }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    private func failed(title: String, detail: String, progress: StashScraper.ScrapeProgress?) -> some View {
        card(tint: .orange) {
            headerRow(icon: "exclamationmark.triangle.fill", tint: .orange, title: title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                ForEach(progress.entries) { entry in sourceRow(entry) }
            }
            actions
        }
    }

    // MARK: Pieces

    private func card<Content: View>(tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
    }

    private func headerRow(icon: String, tint: Color, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
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
        }
    }

    private func sourceRow(_ entry: StashScraper.ScrapeProgress.Entry) -> some View {
        HStack(spacing: 8) {
            Group {
                switch entry.state {
                case .searching:
                    ProgressView().controlSize(.mini)
                case .matched:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .noMatch:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .unreachable:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(fg)
            Spacer(minLength: 0)
            switch entry.state {
            case .searching:
                Text("Searching…").font(.caption).foregroundStyle(.secondary)
            case .matched:
                Text("Match found").font(.caption).foregroundStyle(.green)
            case .noMatch:
                Text("No match").font(.caption).foregroundStyle(.secondary)
            case .unreachable:
                Text("Unreachable").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if onRetry != nil || (secondaryTitle != nil && onSecondary != nil) {
            HStack(spacing: 8) {
                if let onRetry {
                    Button(action: onRetry) {
                        Label(retryTitle, systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let secondaryTitle, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(fg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(fg.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Thin progress bar. `fraction == nil` = indeterminate (a bar sweeping the track); otherwise the filled
/// part is the finished share and a faint sweep keeps running over the unfilled rest, so a long wait on
/// the last source still reads as alive. Callers set the value inside `withAnimation` so the fill glides.
private struct ScrapeBar: View {
    let fraction: Double?
    let tint: Color
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.16))
                Capsule()
                    .fill(tint.opacity(fraction == nil ? 1 : 0.4))
                    .frame(width: width * 0.3)
                    .offset(x: sweep ? width * 0.7 : 0)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: width * min(max(fraction, 0), 1))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Search progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

/// "Try a different spelling" row for a nothing-found performer search: a capsule field + Search button.
struct ScrapeRetryField: View {
    let label: String
    var placeholder = ""
    @Binding var text: String
    var buttonTitle = "Search"
    var disabled = false
    var onSubmit: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    private var blank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { if !blank && !disabled { onSubmit() } }
                    .capsuleField(foreground: themeManager.current.foregroundColor)
                Button(action: onSubmit) {
                    Text(buttonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(blank || disabled ? Color.secondary : themeManager.current.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(themeManager.current.accentColor.opacity(blank || disabled ? 0.05 : 0.14),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(blank || disabled)
            }
        }
    }
}
