import SwiftUI

/// One tile on the glasses — a scene poster, or the trailing "View More" affordance when `scene` is nil.
/// Shared by the wall and the full-list grid so the focus treatment is identical in both (the wearer
/// learns one selection language).
///
/// Cards carry no text: identity lives in the fixed metadata block, so a shelf reads as imagery.
/// Posters are deliberately UNBLURRED regardless of Privacy Mode — the optical path is wearer-only and
/// that privacy IS the feature; the phone-side remote is the surface that suppresses everything.
///
/// Sizing contract: the card is DRAWN at `drawn` (the focused size) and scaled DOWN to `slot` when
/// unfocused. Drawing small and scaling up would resample the focused card from too few pixels — soft
/// edges, a mushy ring, and a visible sharp/soft pulse against native-resolution content. Downsampling
/// never softens; upsampling always does.
struct GlassesPosterCard: View {
    let scene: StashScene?
    /// Subtitle under the View More tile ("128 scenes"). Ignored for poster tiles.
    var moreSubtitle: String = ""
    let imageCache: ImageCache
    let apiKey: String
    let localThumb: URL?
    let focused: Bool
    let slot: CGSize
    let drawn: CGSize

    @State private var poster: UIImage?

    // Derived so the wall (576 wide) and the grid (480 wide) stay visually consistent without a second
    // constants table: 576/32 = 18 and 480/32 = 15; 576/96 = 6 and 480/96 = 5.
    private var corner: CGFloat { drawn.width / 32 }
    private var ringWidth: CGFloat { drawn.width / 96 }
    private var restScale: CGFloat { slot.width / drawn.width }

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if scene == nil {
                moreTile
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
                Image(systemName: "film")
                    .font(.system(size: drawn.width / 10, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(.white.opacity(focused ? 0.92 : 0), lineWidth: ringWidth)
        }
        .scaleEffect(focused ? 1.0 : restScale)
        .shadow(color: .black.opacity(focused ? 0.85 : 0), radius: 26, y: 12)   // contact shadow
        .shadow(color: .white.opacity(focused ? 0.25 : 0), radius: 30)          // lit glow
        .opacity(focused ? 1.0 : 0.38)
        .offset(y: focused ? -drawn.height / 23 : 0)
        // Siblings draw in layout order, so without this the NEXT tile overdraws the focused tile's
        // overhang and glow.
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: focused)
        // LAYOUT slot LAST: pitch stays constant for every tile, and .frame does not clip, so the
        // focused tile overhangs symmetrically and simply covers part of each neighbour. Occlusion is
        // the strongest depth cue there is.
        .frame(width: slot.width, height: slot.height)
        .task(id: scene?.id) {
            guard let scene else { return }
            // Server screenshot first. NOTE: `localThumb` is a byte copy of this same
            // `paths.screenshot` (DownloadManager.fetchSidecar writes `<id>-thumb.jpg`), so the order
            // is a CACHE-LOCALITY choice — it shares the phone grid's entry and self-heals a
            // regenerated cover — NOT an image-content one.
            if let url = scene.thumbnailURL(apiKey: apiKey) {
                poster = try? await imageCache.image(for: url)
            }
            if poster == nil, let localThumb {
                poster = await imageCache.localImage(at: localThumb)
            }
        }
    }

    private var moreTile: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            VStack(spacing: 14) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: drawn.width / 9, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                Text("View More")
                    .font(.system(size: drawn.width / 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                if !moreSubtitle.isEmpty {
                    Text(moreSubtitle)
                        .font(.system(size: drawn.width / 24, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
        }
    }
}
