import SwiftUI

struct SceneDetailView: View {
    let scene: StashScene
    @Binding var path: [Route]
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var isFullscreen = false

    private var stream: (url: URL, isHLS: Bool)? {
        guard let client = appState.client else { return nil }
        return scene.preferredStream(apiKey: client.apiKey)
    }

    var body: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            // Inline player box is sized for 16:9 (full width), so a 16:9 video fills it exactly with
            // no top/bottom blur. Other aspect ratios fit inside this box (blur fills the gaps). The
            // player also extends up behind the status bar, where the blurred backdrop blends in.
            let boxHeight = geo.size.width * 9 / 16

            ZStack(alignment: .top) {
                // Fixed (no-scroll) layout: player up top, compact metadata fills the rest.
                VStack(spacing: 0) {
                    Color.clear.frame(height: boxHeight)
                    metadata
                }
                .opacity(isFullscreen ? 0 : 1)

                // Single player instance — resized in place for fullscreen (no re-parenting), which
                // keeps the render surface alive across the rotation that previously blanked it.
                Group {
                    if let stream {
                        ScenePlayerView(
                            scene: scene,
                            apiKey: apiKey,
                            url: stream.url,
                            preferAVPlayer: stream.isHLS,
                            contentTopInset: topInset,
                            isFullscreen: $isFullscreen,
                            onBack: { dismiss() }
                        )
                    } else {
                        Rectangle()
                            .fill(.black)
                            .overlay { ProgressView().tint(.white) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : boxHeight + topInset, alignment: .top)
                .ignoresSafeArea(edges: isFullscreen ? .all : .top)
            }
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(isFullscreen)
        .background(EnableSwipeBack()) // keep edge-swipe back even with the nav bar hidden
    }

    private var metadata: some View {
        let spacing: CGFloat = 10
        return GeometryReader { geo in
            // Top row (performer + socials) is sized so the enlarged performer card reaches at least
            // the bottom of the socials card; the tags card then fills down to just above the specs box.
            let topRowHeight = min(max(geo.size.height * 0.46, 170), 230)
            VStack(spacing: spacing) {
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
                .frame(maxWidth: .infinity, alignment: .leading)

                // Performer card (left, enlarged) + socials stack (right, truncated to fit).
                HStack(alignment: .top, spacing: spacing) {
                    ScenePerformerCard(performers: scene.performers, apiKey: apiKey) { performer in
                        path.openPerformer(performer)
                    }
                    .frame(width: 150, height: topRowHeight)
                    SocialsCard(links: socialLinks ?? [])
                        .frame(maxWidth: .infinity)
                        .frame(height: topRowHeight)
                }

                // Tags card — full width of the two cards above, scrolls internally when it overflows.
                TagsCard(tags: scene.tags)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                techBox
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.top, spacing)
            .padding(.bottom, 12)
        }
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
        if let ar = scene.aspectRatioLabel { out.append((ar, "aspectratio")) }
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

/// Enlarged, left-aligned performer card for the scene screen: a large portrait of the primary
/// performer with name + age · country overlaid, tappable to open the performer. A "+N" badge marks
/// scenes with extra performers.
struct ScenePerformerCard: View {
    let performers: [Performer]
    let apiKey: String
    var onOpen: (Performer) -> Void
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false
    @State private var image: UIImage?

    var body: some View {
        if let performer = performers.first {
            Button { onOpen(performer) } label: {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(themeManager.current.surfaceColor)
                        .overlay {
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .blur(radius: blurThumbnails ? 26 : 0)
                            } else {
                                PerformerPlaceholder()
                            }
                        }
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center, endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(performer.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .blur(radius: blurTitles ? 5 : 0)
                        HStack(spacing: 5) {
                            if let age = performer.age { Text("\(age)") }
                            if let country = performer.country, !country.isEmpty { Text(country.countryFlag) }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(10)

                    if performers.count > 1 {
                        Text("+\(performers.count - 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .task(id: performer.id) {
                guard let url = performer.imageURL(apiKey: apiKey) else { return }
                image = try? await imageCache.image(for: url)
            }
        } else {
            PerformerPlaceholder()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
