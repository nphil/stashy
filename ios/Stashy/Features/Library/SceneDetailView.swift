import SwiftUI

struct SceneDetailView: View {
    let scene: StashScene
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var isFullscreen = false

    // Inline player fills the width at 16:9 and sits at the very top (below the status bar).
    private var inlineHeight: CGFloat { UIScreen.main.bounds.width * 9 / 16 }

    private var streamURL: URL? {
        guard let client = appState.client else { return nil }
        return scene.preferredStreamURL(apiKey: client.apiKey)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Metadata scrolls behind the inline player (reserve space with a clear spacer).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: inlineHeight)
                    metadata
                }
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
        VStack(alignment: .leading, spacing: 20) {
                    // Title + studio
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scene.title ?? "Untitled")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let studio = scene.studio {
                            Label(studio.name, systemImage: "building.2")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Date + duration
                    HStack(spacing: 16) {
                        if let date = scene.date {
                            Label(date, systemImage: "calendar")
                        }
                        if let dur = scene.formattedDuration() {
                            Label(dur, systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // File(s)
                    if !scene.files.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(scene.files.count > 1 ? "Files" : "File", systemImage: "doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(scene.files.enumerated()), id: \.offset) { _, file in
                                if let name = file.basename {
                                    Text(name)
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }

                            HStack(spacing: 12) {
                                if let res = scene.resolutionLabel {
                                    Label(res, systemImage: "rectangle.compress.vertical")
                                }
                                if let codec = scene.codecLabel {
                                    Label(codec, systemImage: "film")
                                }
                                if let size = scene.files.first?.size {
                                    Label(
                                        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                                        systemImage: "internaldrive"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    // Performers
                    if !scene.performers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Performers", systemImage: "person.2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(scene.performers) { performer in
                                        NavigationLink(value: performer) {
                                            PerformerCard(performer: performer, apiKey: apiKey, width: 104)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // Tags
                    if !scene.tags.isEmpty {
                        ChipSection(title: "Tags", systemImage: "tag") {
                            scene.tags.map(\.name)
                        }
                    }
                }
                .padding(16)
        }

    private var apiKey: String { appState.client?.apiKey ?? "" }
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
