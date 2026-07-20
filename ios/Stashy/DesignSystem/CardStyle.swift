import SwiftUI

/// Shared corner-radius scale (design-system primitive).
enum CornerRadius {
    static let card: CGFloat = 12
    static let small: CGFloat = 10
    static let detail: CGFloat = 16   // the larger radius used by the scene/performer detail cards
    static let large: CGFloat = 18
}

extension View {
    /// A cheap contour separating grid media from the mesh. The former blurred elevation shadow still
    /// consumed compositor fill-rate for every visible card at 120 Hz, even though its source was already
    /// a vector path. A sub-point stroke preserves edge definition without a blur pass.
    func cardContour(isDark: Bool, cornerRadius: CGFloat = CornerRadius.card) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.10),
                    lineWidth: 0.75
                )
        )
    }

    /// Translucent-dark capsule behind a small badge floated over media (scene duration, rating, "+N"
    /// performers). One definition keeps the media-overlay badges visually identical.
    func overlayBadge() -> some View {
        background(.black.opacity(0.55), in: Capsule())
    }

    /// Standard rounded surface for the scene/performer detail cards (and the Downloads card) — a filled
    /// `color` rounded at the shared detail radius. Keeps every detail card's surface identical.
    func detailCardBackground(_ color: Color) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: CornerRadius.detail, style: .continuous))
    }
}
