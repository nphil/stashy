import SwiftUI

/// A blurred, slowly-evolving backdrop for the inline player, sourced from the scene's already-loaded
/// sprite thumbnails at the current playhead. It matches the playing content (real frames, so it
/// blends with the sharp video), costs nothing extra (no second decode — the sprites are already in
/// memory for scrubbing), and changes only when the playhead crosses a sprite cue (every several
/// seconds), cross-dissolving smoothly so it never looks hitchy.
struct AmbientBlurBackdrop: View {
    let sprites: SpriteThumbnails
    let time: TimeInterval
    let fallback: UIImage?

    // Two persistent layers so the outgoing and incoming tiles overlap during the blend.
    @State private var base: UIImage?
    @State private var incoming: UIImage?
    @State private var incomingOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black
            if let base { blurred(base) }
            if let incoming { blurred(incoming).opacity(incomingOpacity) }
        }
        .onAppear { refresh() }
        .onChange(of: time) { _, _ in refresh() }
    }

    private func blurred(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .blur(radius: 32)
            .clipped()
    }

    private func refresh() {
        let next = sprites.thumbnail(at: time) ?? fallback
        guard let next else { return }
        if base == nil { base = next; return }          // first frame, no animation
        if next === base || incoming != nil { return }   // unchanged, or a blend is already running
        incoming = next
        incomingOpacity = 0
        // Overlapping cross-dissolve: both heavily-blurred stills stay on screen for the whole blend,
        // so the change reads as one smooth color morph rather than a switch.
        withAnimation(.easeInOut(duration: 1.1)) {
            incomingOpacity = 1
        } completion: {
            base = next
            incoming = nil
            incomingOpacity = 0
        }
    }
}
