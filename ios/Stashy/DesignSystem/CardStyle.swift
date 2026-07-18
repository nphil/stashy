import SwiftUI

/// Shared corner-radius scale (design-system primitive).
enum CornerRadius {
    static let card: CGFloat = 12
    static let small: CGFloat = 10
    static let large: CGFloat = 18
}

extension View {
    /// A subtle, perf-conscious shadow so a content card floats over the themed mesh background. The small
    /// radius keeps the per-cell offscreen cost low on scrolling grids; opacity is a touch deeper on dark
    /// palettes. Apply after the card's `clipShape`.
    func cardElevation(isDark: Bool) -> some View {
        shadow(color: .black.opacity(isDark ? 0.28 : 0.12), radius: 4, y: 2)
    }

    /// Translucent-dark capsule behind a small badge floated over media (scene duration, rating, "+N"
    /// performers). One definition keeps the media-overlay badges visually identical.
    func overlayBadge() -> some View {
        background(.black.opacity(0.55), in: Capsule())
    }
}
