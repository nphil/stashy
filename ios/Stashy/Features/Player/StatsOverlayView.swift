import SwiftUI

/// A clean, translucent on-video diagnostics panel. Refreshes once a second via `TimelineView` (off the
/// render path), pulling a fresh `PlaybackStats` snapshot from the model. Section-based so the future
/// Stash-transcoder stats slot in without changing this view.
struct StatsOverlayView: View {
    let scene: StashScene
    let model: ScenePlayerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            panel(model.snapshotStats(scene: scene))
        }
    }

    private func panel(_ stats: PlaybackStats) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(stats.sections) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                        ForEach(section.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.label)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 88, alignment: .leading)
                                Text(line.value)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 264)
        .frame(maxHeight: 300)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }
}
