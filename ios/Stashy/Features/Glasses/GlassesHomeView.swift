import SwiftUI

/// The 10-foot home on the glasses: horizontal rails of poster cards under a fixed focus slot.
///
/// Layout is specified in raw pixels — the external scene is 1920×1080 at scale 1.0, so pt == px.
/// Focus never moves: the CONTENT slides under a fixed slot (Apple TV model), so the wearer's eye and
/// the remote's swipe→motion mapping stay constant. All rendering is opacity/transform-only at the
/// external screen's 60 Hz. No glass, no materials — nothing to refract over black (the documented
/// glass-over-flat landmine), and thin type halos on a birdbath optic, so weights stay ≥ medium.
struct GlassesHomeView: View {
    @Bindable var coordinator: GlassesCoordinator
    let imageCache: ImageCache
    let apiKey: String
    /// Downloaded-scene thumbnail on disk (offline poster), by scene id. Injected because the thumb
    /// lives on `DownloadItem`, not `StashScene`.
    let localThumb: (String) -> URL?

    private static let cardSize = CGSize(width: 384, height: 216)
    private static let gutter: CGFloat = 24
    private static var pitch: CGFloat { cardSize.width + gutter }
    private static let sideMargin: CGFloat = 96
    private static let railPitch: CGFloat = 320

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            // Rails slide vertically so the focused rail sits at a fixed height.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(coordinator.rails.enumerated()), id: \.element.id) { railIdx, rail in
                    railView(rail, railIdx: railIdx)
                        .frame(height: Self.railPitch, alignment: .top)
                }
            }
            .offset(y: 200 - CGFloat(coordinator.railIndex) * Self.railPitch)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: coordinator.railIndex)

            focusedTitleBlock
        }
    }

    private func railView(_ rail: GlassesCoordinator.Rail, railIdx: Int) -> some View {
        let isFocusedRail = railIdx == coordinator.railIndex
        let focusItem = isFocusedRail ? coordinator.itemIndex : 0
        return VStack(alignment: .leading, spacing: 18) {
            Text(rail.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(isFocusedRail ? 0.9 : 0.45))
                .padding(.leading, Self.sideMargin)

            // The row slides so the focused card sits at the fixed left margin.
            HStack(spacing: Self.gutter) {
                ForEach(Array(rail.scenes.enumerated()), id: \.element.id) { idx, scene in
                    GlassesPosterCard(
                        scene: scene,
                        imageCache: imageCache,
                        apiKey: apiKey,
                        localThumb: localThumb(scene.id),
                        focused: isFocusedRail && idx == coordinator.itemIndex
                    )
                }
            }
            .padding(.leading, Self.sideMargin)
            .offset(x: -CGFloat(focusItem) * Self.pitch)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focusItem)
            .opacity(isFocusedRail ? 1 : 0.30)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: coordinator.railIndex)
    }

    /// Fixed text block under the focused rail: the one place titles/metadata render (cards stay clean).
    private var focusedTitleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let scene = coordinator.focusedScene {
                Text(scene.title ?? "Untitled")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let rail = coordinator.rails.indices.contains(coordinator.railIndex)
                    ? coordinator.rails[coordinator.railIndex] : nil {
                    Text("\(coordinator.itemIndex + 1) of \(rail.scenes.count)")
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.leading, Self.sideMargin)
        .padding(.top, 200 + Self.railPitch)
        .animation(.easeOut(duration: 0.15), value: coordinator.focusedScene?.id)
    }
}

/// One poster card. Cards carry no text — identity lives in the fixed title block, so the shelf reads
/// as imagery. Posters are deliberately UNBLURRED regardless of Privacy Mode: the optical path is
/// wearer-only, and that privacy IS the feature (the phone-side remote is what suppresses titles).
private struct GlassesPosterCard: View {
    let scene: StashScene
    let imageCache: ImageCache
    let apiKey: String
    let localThumb: URL?
    let focused: Bool
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
                Image(systemName: "film")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .frame(width: 384, height: 216)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(focused ? 0.92 : 0), lineWidth: 5)
        }
        .shadow(color: .white.opacity(focused ? 0.30 : 0), radius: 34)
        // 1.08 was device-tested and read as ambiguous at cinema distance — the selection must be
        // unmistakable in peripheral vision, not a detail you check. 18% pop + a lift + a deep dim on
        // everything unfocused makes the focused card the only bright thing on the shelf.
        .scaleEffect(focused ? 1.18 : 1.0)
        .offset(y: focused ? -10 : 0)
        .opacity(focused ? 1.0 : 0.45)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focused)
        .task(id: scene.id) {
            // Server screenshot FIRST: the phone grid and the remote's status card use it, so the
            // wall must too or a downloaded scene wears a different image on each screen (the
            // download-time local frame grab is a different frame entirely, and it made the glasses
            // look out of sync with the remote). The local thumb is the offline fallback only.
            if let url = scene.thumbnailURL(apiKey: apiKey) {
                poster = try? await imageCache.image(for: url)
            }
            if poster == nil, let localThumb {
                poster = await imageCache.localImage(at: localThumb)
            }
        }
    }
}
