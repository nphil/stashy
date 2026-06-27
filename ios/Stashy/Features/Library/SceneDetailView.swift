import SwiftUI
import AVKit

struct SceneDetailView: View {
    let scene: Scene
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @State private var player: AVPlayer?
    @State private var showFullscreen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Video player
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let player {
                            VideoPlayer(player: player)
                        } else {
                            Rectangle()
                                .fill(.black)
                                .overlay { ProgressView().tint(.white) }
                        }
                    }
                    .frame(height: 220)
                    .background(.black)

                    // Fullscreen button
                    if player != nil {
                        Button {
                            showFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(8)
                        }
                        .glassEffect(.regular.interactive(), in: Circle())
                        .padding(10)
                    }
                }

                // Metadata
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

                    // Performers
                    if !scene.performers.isEmpty {
                        ChipSection(title: "Performers", systemImage: "person.2") {
                            scene.performers.map(\.name)
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
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { setupPlayer() }
        .onDisappear { player?.pause() }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenPlayerView(player: player)
        }
    }

    private func setupPlayer() {
        guard let client = appState.client,
              let streamURL = scene.preferredStreamURL(apiKey: client.apiKey) else { return }
        let item = AVPlayerItem(url: streamURL)
        let p = AVPlayer(playerItem: item)
        p.preferredForwardBufferDuration = 5
        player = p
        p.play()
    }
}

// MARK: - Fullscreen player

struct FullscreenPlayerView: View {
    let player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .padding()
        }
        .onAppear { player?.play() }
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
