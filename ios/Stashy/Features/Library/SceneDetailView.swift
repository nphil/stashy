import SwiftUI

struct SceneDetailView: View {
    let scene: StashScene
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var isFullscreen = false

    // Inline player fills the width at 16:9 and sits at the very top (below the status bar).
    private var inlineHeight: CGFloat { UIScreen.main.bounds.width * 9 / 16 }

    private var streamURL: URL? {
        guard let client = appState.client else { return nil }
        return scene.preferredStreamURL(apiKey: client.apiKey)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Fixed (no-scroll) layout: player up top, compact metadata fills the rest.
            VStack(spacing: 0) {
                Color.clear.frame(height: inlineHeight)
                metadata
            }
            .opacity(isFullscreen ? 0 : 1)

            // Single player instance — resized in place for fullscreen (no re-parenting), which
            // keeps the render surface alive across the rotation that previously blanked it.
            Group {
                if let streamURL {
                    ScenePlayerView(
                        scene: scene,
                        apiKey: apiKey,
                        url: streamURL,
                        isFullscreen: $isFullscreen,
                        onBack: { dismiss() }
                    )
                } else {
                    Rectangle()
                        .fill(.black)
                        .overlay { ProgressView().tint(.white) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : inlineHeight)
            .background(.black)
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(isFullscreen)
        .background(EnableSwipeBack()) // keep edge-swipe back even with the nav bar hidden
        .navigationDestination(for: Performer.self) { performer in
            PerformerDetailView(performer: performer)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + studio + date — deliberately understated.
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.title ?? "Untitled")
                    .font(.headline)
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(1)
                    .blur(radius: blurTitles ? 6 : 0)
                HStack(spacing: 6) {
                    if let studio = scene.studio { Text(studio.name).lineLimit(1) }
                    if let date = scene.date { Text("· \(date)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Performers: who, age, country.
            if !scene.performers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scene.performers) { performer in
                            NavigationLink(value: performer) {
                                CompactPerformerChip(performer: performer, apiKey: apiKey)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Social links (merged across performers), truncated.
            if let links = socialLinks {
                FlowLayout(spacing: 6) {
                    ForEach(links.prefix(4), id: \.url) { link in
                        Link(destination: link.url) {
                            Label(link.label, systemImage: link.symbol)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .glassEffect(.regular.tint(themeManager.current.accentColor), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Tags (ranked + truncated).
            if !scene.tags.isEmpty {
                TagChipsView(tags: scene.tags)
            }

            Spacer(minLength: 0)

            techBox
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var socialLinks: [SocialLink]? {
        let raw = scene.performers.flatMap { $0.urls ?? [] }
        let links = raw.compactMap { SocialLink(raw: $0) }
        guard !links.isEmpty else { return nil }
        var seen = Set<URL>()
        return links.filter { seen.insert($0.url).inserted }.sorted { $0.priority < $1.priority }
    }

    private var techItems: [(label: String, symbol: String)] {
        var out: [(String, String)] = []
        if let r = scene.resolutionLabel { out.append((r, "rectangle.compress.vertical")) }
        if let c = scene.codecLabel { out.append((c, "film")) }
        if let b = scene.bitrateLabel { out.append((b, "speedometer")) }
        if let f = scene.frameRateLabel { out.append((f, "timelapse")) }
        if let d = scene.formattedDuration() { out.append((d, "clock")) }
        if let s = scene.fileSizeLabel { out.append((s, "internaldrive")) }
        return out
    }

    @ViewBuilder private var techBox: some View {
        let items = techItems
        if !items.isEmpty {
            FlowLayout(spacing: 10) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 9))
                        Text(item.label)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var apiKey: String { appState.client?.apiKey ?? "" }
}

/// Compact performer chip for the scene screen: small portrait + name + age · country.
struct CompactPerformerChip: View {
    let performer: Performer
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: blurThumbnails ? 14 : 0)
                } else {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(performer.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(1)
                    .blur(radius: blurTitles ? 5 : 0)
                HStack(spacing: 4) {
                    if let age = performer.age { Text("\(age)") }
                    if let country = performer.country, !country.isEmpty { Text(country.countryFlag) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.trailing, 4)
        }
        .padding(6)
        .background(themeManager.current.surfaceColor, in: Capsule())
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            image = try? await imageCache.image(for: url)
        }
    }
}

// MARK: - Chip section

struct ChipSection: View {
    let title: String
    let systemImage: String
    let chips: () -> [String]
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(chips(), id: \.self) { chip in
                        Text(chip)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - Ranked, truncating tag chips

/// Tag chips ordered by the user's tag history + Stash popularity, truncated to the most relevant
/// with an expand toggle so long tag lists stay compact.
struct TagChipsView: View {
    let tags: [Tag]
    private let limit = 8
    @State private var expanded = false
    @Environment(AppRouter.self) private var router

    var body: some View {
        let ranked = TagRankingStore.shared.ranked(tags)
        let shown = expanded ? ranked : Array(ranked.prefix(limit))

        VStack(alignment: .leading, spacing: 8) {
            Label("Tags", systemImage: "tag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(shown) { tag in
                        Button { router.openScenes(tag: tag) } label: {
                            Text(tag.name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if ranked.count > limit {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show less" : "+\(ranked.count - limit)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Flow layout (wrapping chip row)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, in: proposal.replacingUnspecifiedDimensions())
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.size)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(subviews: Subviews, in size: CGSize) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        var maxX: CGFloat = 0

        for subview in subviews {
            let viewSize = subview.sizeThatFits(.unspecified)
            if x + viewSize.width > size.width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: viewSize))
            rowHeight = max(rowHeight, viewSize.height)
            x += viewSize.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}
