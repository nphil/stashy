import SwiftUI

/// The full list behind a rail's "View More" tile: a 5-wide grid at 1920×1080 with the same focus
/// treatment as the wall, so the wearer learns one selection language.
///
/// Same 10-foot rules as the wall: pt == px, opacity/transform-only at 60 Hz, no glass over black,
/// white never above 0.92, and tiles carry no text — identity lives in the fixed header.
struct GlassesGridView: View {
    @Bindable var coordinator: GlassesCoordinator
    let imageCache: ImageCache
    let apiKey: String
    let localThumb: (String) -> URL?

    private static let slot = CGSize(width: 320, height: 180)
    private static let drawn = CGSize(width: 480, height: 270)   // 1.5×, same ratio as the wall
    private static let hGutter: CGFloat = 32
    private static let hPitch: CGFloat = 352
    private static let leftMargin: CGFloat = 96                  // row spans 96…1824, symmetric
    private static let vPitch: CGFloat = 290
    /// 205, not 180: the focused tile is drawn 270 tall inside a 180 slot and lifted, so its visual top
    /// sits ~57 pt above the slot — at 180 it overlapped the 143 pt header block.
    private static let gridTop: CGFloat = 205

    /// Focused row sits in the SECOND visible slot; row 0 over-scrolls, deliberately consistent with
    /// the wall's fixed gaze point.
    private var rowsOffsetY: CGFloat {
        Self.gridTop - CGFloat(max(0, coordinator.gridRow - 1)) * Self.vPitch
    }

    /// Render window only. These stacks are NOT lazy — a 400-scene list would otherwise fire 400
    /// concurrent poster fetches at the Stash box on open.
    private var visibleRows: [Int] {
        guard coordinator.gridRowCount > 0 else { return [] }
        let lo = max(0, coordinator.gridRow - 2)
        let hi = min(coordinator.gridRowCount - 1, coordinator.gridRow + 2)
        return lo <= hi ? Array(lo...hi) : []
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            header

            ZStack(alignment: .topLeading) {
                ForEach(visibleRows, id: \.self) { row in
                    rowView(row)
                        .offset(y: CGFloat(row) * Self.vPitch)
                        .zIndex(row == coordinator.gridRow ? 1 : 0)
                }
            }
            .offset(y: rowsOffsetY)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: coordinator.gridIndex)

            if coordinator.gridItems.isEmpty { loadingBlock }
        }
        // Same mandatory pin as the wall: these rows report their ideal width, and SwiftUI's root
        // centres anything larger than its host.
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(coordinator.gridSource?.title ?? "")  ·  \(min(coordinator.gridIndex + 1, max(coordinator.gridTotal, 1))) of \(coordinator.gridTotal)")
                .font(.system(size: 26, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 31, alignment: .leading)
            Text(coordinator.gridFocusedScene?.title ?? "")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 1728, alignment: .leading)
                .frame(height: 48, alignment: .leading)
        }
        .padding(.leading, Self.leftMargin)
        .padding(.top, 56)
        .animation(.easeOut(duration: 0.15), value: coordinator.gridFocusedScene?.id)
    }

    private func rowView(_ row: Int) -> some View {
        let start = row * GlassesCoordinator.gridColumns
        let end = min(start + GlassesCoordinator.gridColumns, coordinator.gridItems.count)
        return HStack(spacing: Self.hGutter) {
            ForEach(Array(coordinator.gridItems[start..<end].enumerated()), id: \.element.id) { offset, scene in
                GlassesPosterCard(
                    scene: scene,
                    imageCache: imageCache,
                    apiKey: apiKey,
                    localThumb: localThumb(scene.id),
                    focused: start + offset == coordinator.gridIndex,
                    slot: Self.slot,
                    drawn: Self.drawn
                )
            }
        }
        .padding(.leading, Self.leftMargin)
        .frame(width: 1920, alignment: .leading)
    }

    /// Never a terminal error state — the coordinator's loader retries forever with backoff, so this
    /// says "reconnecting", not "failed" (the jobs-panel rule).
    private var loadingBlock: some View {
        VStack(spacing: 18) {
            ProgressView().tint(.white.opacity(0.7)).scaleEffect(1.6)
            Text(coordinator.gridReconnecting ? "Reconnecting…" : "Loading…")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: 1920, height: 1080)
    }
}
