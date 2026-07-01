import SwiftUI

/// Interactive 5-star rating mapped onto Stash's 0–100 scale. Tap a star to set it, drag across the row
/// to sweep, or tap the current top star to clear. Emits the new `rating100` (nil = cleared) via
/// `onChange`; callers apply it optimistically and persist. In read-only mode it renders half-stars for
/// fractional values (e.g. 70 → 3.5 stars) and takes no input.
struct StarRating: View {
    let rating100: Int?
    var starSize: CGFloat = 22
    var spacing: CGFloat = 4
    var interactive: Bool = true
    var color: Color = .yellow
    var emptyColor: Color = .secondary
    /// New rating on a 0–100 scale, or nil when cleared. Only called in interactive mode.
    var onChange: ((Int?) -> Void)? = nil

    /// 0…5, fractional — drives half-star display.
    private var stars: Double { Double(rating100 ?? 0) / 20.0 }
    private var stride: CGFloat { starSize + spacing }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: symbol(for: i))
                    .resizable().scaledToFit()
                    .frame(width: starSize, height: starSize)
                    .foregroundStyle(symbol(for: i) == "star" ? emptyColor.opacity(0.35) : color)
            }
        }
        .symbolEffect(.bounce, value: rating100)
        .contentShape(Rectangle())
        .modifier(RatingGesture(enabled: interactive, stride: stride, current: rating100, onChange: onChange))
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(rating100.map { "\($0 / 20) of 5 stars" } ?? "Not rated")
    }

    private func symbol(for index: Int) -> String {
        let i = Double(index)
        if stars >= i { return "star.fill" }
        if stars >= i - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Maps a tap or horizontal drag over the star row to a whole-star rating (1–5 → 20–100). A pure tap on
/// the current top star clears the rating; drags never clear (so a sweep can't accidentally reset it).
private struct RatingGesture: ViewModifier {
    let enabled: Bool
    let stride: CGFloat
    let current: Int?
    let onChange: ((Int?) -> Void)?

    func body(content: Content) -> some View {
        guard enabled else { return AnyView(content) }
        return AnyView(content.gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let star = max(1, min(5, Int((value.location.x / stride).rounded(.up))))
                    let rating = star * 20
                    let isTap = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                    let cleared = isTap && rating == current
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onChange?(cleared ? nil : rating)
                }
        ))
    }
}

/// A favorite toggle rendered as a heart. Fills pink when on, with a bounce on change and a soft shadow
/// so it stays legible over imagery. Emits the intended new value via `onToggle`; the caller applies it
/// optimistically and persists.
struct FavoriteHeart: View {
    let isFavorite: Bool
    var size: CGFloat = 20
    var onColor: Color = .pink
    var offColor: Color = .white
    var onToggle: (Bool) -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onToggle(!isFavorite)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isFavorite ? onColor : offColor.opacity(0.9))
                .symbolEffect(.bounce, value: isFavorite)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }
}
