import SwiftUI

/// Shared card building blocks for the scene- and performer-detail screens, which follow the same
/// UI rules: fixed one-screen layouts, evenly-spaced rounded cards, tag chips that deep-link into a
/// filtered Scenes list, and social links truncated by priority to fit their card.

extension View {
    /// Immersive scroll: fade a vertical `ScrollView`'s top/bottom edges so content dissolves into the card
    /// instead of hard-cutting — but only where there's actually off-screen content. At the very top there's
    /// no top fade; it ramps in as you scroll away, and the bottom fade disappears once you reach the end.
    /// If the content fits (not scrollable), no fade at all. Apply to the `ScrollView`.
    func scrollEdgeFade(length: CGFloat = 22) -> some View {
        modifier(ScrollEdgeFade(length: length))
    }
}

private struct ScrollFadeMetrics: Equatable { var top: CGFloat; var bottom: CGFloat }

/// Tracks scroll position vs content/container size and drives a dynamic top/bottom alpha fade.
private struct ScrollEdgeFade: ViewModifier {
    let length: CGFloat
    @State private var top: CGFloat = 0      // 0 = no top fade (at the top edge), 1 = fully faded
    @State private var bottom: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollFadeMetrics.self) { geo in
                let offset = geo.contentOffset.y + geo.contentInsets.top
                let maxOffset = geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom
                    - geo.containerSize.height
                let scrollable = maxOffset > 1
                return ScrollFadeMetrics(
                    top: scrollable ? min(1, max(0, offset / length)) : 0,
                    bottom: scrollable ? min(1, max(0, (maxOffset - offset) / length)) : 0
                )
            } action: { _, m in
                top = m.top
                bottom = m.bottom
            }
            .mask(
                VStack(spacing: 0) {
                    // Edge alpha is 1 (visible) when at that edge, ramping to 0 as you scroll past it.
                    LinearGradient(colors: [.black.opacity(1 - top), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .black.opacity(1 - bottom)], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                }
            )
    }
}

// MARK: - Tags card

/// A fixed-footprint card of ranked tag chips. Tags are ordered by the user's tag history + Stash
/// popularity; the card scrolls internally when they overflow so the surrounding screen never grows.
/// Tapping a tag deep-links to the Scenes tab filtered by just that tag.
struct TagsCard: View {
    let tags: [Tag]
    var title = "Tags"
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router

    var body: some View {
        let ranked = TagRankingStore.shared.ranked(tags)
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "tag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if ranked.isEmpty {
                Text("No tags")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    FlowLayout(spacing: 6) {
                        ForEach(ranked) { tag in
                            Button { router.openScenes(tag: tag) } label: {
                                Text(tag.name)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .glassEffect(.regular, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .scrollEdgeFade()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailCardBackground(themeManager.current.surfaceColor)
    }
}

// MARK: - Socials card

/// A vertical stack of social links (highest-priority first), truncated to however many fit the
/// card's height so it never pushes past the performer card beside it.
struct SocialsCard: View {
    let links: [SocialLink]
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Links", systemImage: "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if links.isEmpty {
                Text("No links")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                // Scroll rather than squeezing a fixed number of rows into the card height. The old
                // fit-count math under-counted the row spacing, so more rows were shown than fit and the
                // VStack compressed them until they OVERLAPPED — leaving only the last link hit-testable
                // (why "the links didn't work" / "only the last one is clickable"). A ScrollView keeps every
                // row its natural height (no overlap → all tappable) and lets every link be reached.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                            Link(destination: link.url) {
                                Label(link.label, systemImage: link.symbol)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .glassEffect(.regular.tint(themeManager.current.accentColor), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollEdgeFade()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailCardBackground(themeManager.current.surfaceColor)
    }
}

// MARK: - Stats card

/// Compact grid of labelled stats (used beside the enlarged performer image on the performer screen).
struct StatCard: View {
    let items: [(symbol: String, label: String, value: String)]
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.caption)
                        .foregroundStyle(themeManager.current.accentColor)
                        .frame(width: 18)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(item.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailCardBackground(themeManager.current.surfaceColor)
    }
}
