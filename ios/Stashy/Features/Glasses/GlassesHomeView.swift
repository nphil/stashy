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

    /// Focusable positions in a rail: its scenes, then the View More tile when present. A named type,
    /// not a tuple — `ForEach(…, id: \.element.id)` needs a key path, and Swift has none into tuples.
    /// Stable string ids so a rail whose contents are replaced mid-session doesn't reuse card state
    /// by position.
    private struct RailSlot: Identifiable {
        let id: String
        let scene: StashScene?
    }

    private func slots(for rail: GlassesCoordinator.Rail) -> [RailSlot] {
        rail.scenes.map { RailSlot(id: $0.id, scene: $0) }
            + (rail.more == nil ? [] : [RailSlot(id: "more-\(rail.id)", scene: nil)])
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

            // The row slides so the focused card sits in the fixed centre slot. The trailing slot is
            // the View More tile when the rail has more than it shows — a focusable TILE rather than
            // a button under the header, because the remote's whole browse vocabulary is dx/dy focus
            // steps: a header button would be literally unreachable.
            HStack(spacing: Self.gutter) {
                ForEach(Array(slots(for: rail).enumerated()), id: \.element.id) { idx, slot in
                    GlassesPosterCard(
                        scene: slot.scene,
                        moreSubtitle: "\(rail.total) scenes",
                        imageCache: imageCache,
                        apiKey: apiKey,
                        localThumb: slot.scene.flatMap { localThumb($0.id) },
                        focused: isFocusedRail && idx == coordinator.itemIndex,
                        slot: Self.cardSlot,
                        drawn: Self.focusDraw
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
            if coordinator.rails.indices.contains(coordinator.railIndex) {
                let rail = coordinator.rails[coordinator.railIndex]
                // Never collapses to empty: on the View More tile the block names the affordance.
                Text(coordinator.focusedScene?.displayTitle ?? (coordinator.focusedMoreSource == nil
                                                               ? "Untitled" : "View More"))
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    // Middle, not tail: title fallbacks are file names, whose tail carries the extension.
                    .truncationMode(.middle)
                    .frame(maxWidth: 1440)
                Text(coordinator.focusedMoreSource == nil
                     ? "\(rail.title)  ·  \(coordinator.itemIndex + 1) of \(rail.slotCount)"
                     : "\(rail.title)  ·  \(rail.total) scenes")
                    .font(.system(size: 24, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .frame(width: 1920, height: 92, alignment: .center)
        .padding(.top, Self.metaTop)
        .animation(.easeOut(duration: 0.15), value: coordinator.focusedScene?.id)
    }
}
