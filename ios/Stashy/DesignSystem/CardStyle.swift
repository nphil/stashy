import SwiftUI

/// Shared corner-radius scale (design-system primitive).
enum CornerRadius {
    static let card: CGFloat = 12
    static let small: CGFloat = 10
    static let large: CGFloat = 18
}

extension View {
    /// A subtle shadow so a content card floats over the themed mesh background. Cast the shadow from an
    /// opaque backing `RoundedRectangle`, NOT from the clipped card itself: a `.shadow` on a clipped/rounded
    /// view forces Core Animation to rasterize the whole cell offscreen every frame to derive the shadow's
    /// alpha silhouette — hundreds of offscreen passes/second across a scrolling grid = 120 Hz judder.
    /// Shadowing a plain filled shape uses its known vector path instead (image-independent, cheap). The
    /// backing shape is fully covered by the opaque card, so only its shadow shows; its `cornerRadius` +
    /// `.continuous` MUST match the card's `clipShape`. Apply after the card's `clipShape`.
    func cardElevation(isDark: Bool, cornerRadius: CGFloat = CornerRadius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(isDark ? 0.28 : 0.12), radius: 4, y: 2)
        )
    }

    /// Translucent-dark capsule behind a small badge floated over media (scene duration, rating, "+N"
    /// performers). One definition keeps the media-overlay badges visually identical.
    func overlayBadge() -> some View {
        background(.black.opacity(0.55), in: Capsule())
    }
}
