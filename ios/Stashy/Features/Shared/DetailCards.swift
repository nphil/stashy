import SwiftUI

/// Shared card building blocks for the scene- and performer-detail screens, which follow the same
/// UI rules: fixed one-screen layouts, evenly-spaced rounded cards, tag chips that deep-link into a
/// filtered Scenes list, and social links truncated by priority to fit their card.

private let detailCardCorner: CGFloat = 16

extension View {
    /// Standard rounded surface used by every detail card.
    func detailCardBackground(_ color: Color) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: detailCardCorner, style: .continuous))
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
                ScrollView(showsIndicators: true) {
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
                }
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

    private let rowHeight: CGFloat = 34
    private let headerHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height - headerHeight - 20
            let fit = max(1, Int(available / rowHeight))
            VStack(alignment: .leading, spacing: 6) {
                Label("Links", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if links.isEmpty {
                    Text("No links")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(links.prefix(fit), id: \.url) { link in
                        Link(destination: link.url) {
                            Label(link.label, systemImage: link.symbol)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(themeManager.current.accentColor), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailCardBackground(themeManager.current.surfaceColor)
        }
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
