import SwiftUI

/// The 10-foot home on the glasses: horizontal rails of poster cards under a fixed focus slot.
///
/// Layout is specified in raw pixels — the external scene is 1920×1080 at scale 1.0, so pt == px.
/// Focus never moves: the CONTENT slides under a fixed slot (Apple TV model), so the wearer's eye and
/// the remote's swipe→motion mapping stay constant. All rendering is opacity/transform-only at the
/// external screen's 60 Hz. No glass, no materials — nothing to refract over black (the documented
/// glass-over-flat landmine), and thin type halos on a birdbath optic, so weights stay ≥ medium.
///
/// The focus slot is CENTRED (owner, 2026-08-03). Rows over-scroll at both ends rather than clamping:
/// a fixed gaze point is the whole eyes-free contract, and on micro-OLED the empty margin is pixels-off
/// black, so dead space costs nothing (this is why a lit LCD TV clamps and we deliberately do not).
struct GlassesHomeView: View {
    @Bindable var coordinator: GlassesCoordinator
    let imageCache: ImageCache
    let apiKey: String
    /// Downloaded-scene thumbnail on disk (offline poster), by scene id. Injected because the thumb
    /// lives on `DownloadItem`, not `StashScene`.
    let localThumb: (String) -> URL?

    // Geometry — derived once, never re-derived at a call site.
    static let cardSlot = CGSize(width: 384, height: 216)     // layout footprint
    static let focusDraw = CGSize(width: 576, height: 324)    // pixels actually drawn (1.5×)
    static let restScale: CGFloat = 2.0 / 3.0                 // 384/576 — unfocused cards scale DOWN
    private static let gutter: CGFloat = 24
    private static let pitch: CGFloat = 408                   // 384 + 24
    /// (1920 − 384)/2 — puts every focused slot's centre at screen x 960, at every index, no cases.
    private static let rowLeading: CGFloat = 768
    private static let railTitleHeight: CGFloat = 36
    private static let titleGap: CGFloat = 24
    private static let railPitch: CGFloat = 476
    private static let railsTopY: CGFloat = 272
    private static let metaTop: CGFloat = 612

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            // Rails slide vertically so the focused rail sits at a fixed height.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(coordinator.rails.enumerated()), id: \.element.id) { railIdx, rail in
                    railView(rail, railIdx: railIdx)
                        .frame(height: Self.railPitch, alignment: .top)
                        .zIndex(railIdx == coordinator.railIndex ? 1 : 0)
                }
            }
            .offset(y: Self.railsTopY - CGFloat(coordinator.railIndex) * Self.railPitch)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: coordinator.railIndex)

            focusedTitleBlock
        }
        // MANDATORY. Each rail row is a non-lazy HStack that reports its IDEAL width — 25 cards is
        // 10,272 pt — and SwiftUI's root CENTRES content larger than its host, which shoved the focused
        // card to screen x −4080 and left the wearer looking at cards focus+10…focus+14. That single
        // missing modifier is why the wall "didn't match what's playing" and why the selection looked
        // arbitrary. Do NOT swap this for .clipped(): .frame pins an oversized child by alignment
        // WITHOUT clipping, which is what preserves the focused card's overhang and glow.
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    private func railView(_ rail: GlassesCoordinator.Rail, railIdx: Int) -> some View {
        let isFocusedRail = railIdx == coordinator.railIndex
        let displayIndex = coordinator.displayIndex(for: rail)
        return VStack(alignment: .leading, spacing: Self.titleGap) {
            Text(rail.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(isFocusedRail ? 0.90 : 0.40))
                .frame(height: Self.railTitleHeight, alignment: .leading)
                .padding(.leading, 96)

            // The row slides so the focused card sits in the fixed centre slot.
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
            .padding(.leading, Self.rowLeading)
            .offset(x: -CGFloat(displayIndex) * Self.pitch)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: displayIndex)
            .opacity(isFocusedRail ? 1 : 0.24)
            // .leading, never .center: overflow must extend to the right only, or the row re-centres
            // itself and the offset math above stops meaning anything.
            .frame(width: 1920, alignment: .leading)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: coordinator.railIndex)
    }

    /// Fixed text block under the focused card: the one place titles/metadata render (cards stay clean).
    /// Pinned to the focused card's bottom edge with a FIXED height — deriving its y from railPitch put
    /// it exactly on top of the next rail's header, glyph for glyph.
    private var focusedTitleBlock: some View {
        VStack(alignment: .center, spacing: 8) {
            if let scene = coordinator.focusedScene {
                Text(scene.title ?? "Untitled")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 1440)
                if coordinator.rails.indices.contains(coordinator.railIndex) {
                    let rail = coordinator.rails[coordinator.railIndex]
                    Text("\(rail.title)  ·  \(coordinator.itemIndex + 1) of \(rail.scenes.count)")
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
        }
        .frame(width: 1920, height: 92, alignment: .center)
        .padding(.top, Self.metaTop)
        .animation(.easeOut(duration: 0.15), value: coordinator.focusedScene?.id)
    }
}

/// One poster card. Cards carry no text — identity lives in the fixed title block, so the shelf reads
/// as imagery. Posters are deliberately UNBLURRED regardless of Privacy Mode: the optical path is
/// wearer-only, and that privacy IS the feature (the phone-side remote is what suppresses everything).
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
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        // Draw at FOCUS size and scale DOWN. Drawing at 384 and scaling 1.5× up would resample the
        // focused card from 384 px of real data — soft edges, mushy ring, and a visible sharp/soft
        // pulse against native-res content. Downsampling never softens; upsampling always does.
        .frame(width: GlassesHomeView.focusDraw.width, height: GlassesHomeView.focusDraw.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(focused ? 0.92 : 0), lineWidth: 6)
        }
        .scaleEffect(focused ? 1.0 : GlassesHomeView.restScale)
        .shadow(color: .black.opacity(focused ? 0.85 : 0), radius: 26, y: 12)   // contact shadow
        .shadow(color: .white.opacity(focused ? 0.25 : 0), radius: 30)          // lit glow
        .opacity(focused ? 1.0 : 0.38)
        .offset(y: focused ? -14 : 0)
        // HStack siblings draw in layout order, so without this the NEXT card overdraws the focused
        // card's 96 pt of overhang on the right.
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focused)
        // LAYOUT slot last: pitch stays 408 for every card and .frame does not clip, so the focused
        // card overhangs its slot symmetrically and simply covers 72 pt of each neighbour. Occlusion
        // is the strongest depth cue available and it is exactly the exaggeration that was asked for.
        .frame(width: GlassesHomeView.cardSlot.width, height: GlassesHomeView.cardSlot.height)
        .task(id: scene.id) {
            // Server screenshot first. NOTE: `localThumb` is a byte copy of this same
            // `paths.screenshot` (DownloadManager.fetchSidecar writes `<id>-thumb.jpg`), so this order
            // is a CACHE-LOCALITY choice, not an image-content one — it shares the phone grid's cache
            // entry and self-heals a regenerated cover. It is not what fixed the "wrong thumbnail"
            // report; the wall geometry was.
            if let url = scene.thumbnailURL(apiKey: apiKey) {
                poster = try? await imageCache.image(for: url)
            }
            if poster == nil, let localThumb {
                poster = await imageCache.localImage(at: localThumb)
            }
        }
    }
}
