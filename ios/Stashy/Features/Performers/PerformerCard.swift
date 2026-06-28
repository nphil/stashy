import SwiftUI

/// Portrait card for a performer: image, name, and an optional stat line. Used in the
/// performers grid and the scene-detail performer row.
struct PerformerCard: View {
    let performer: Performer
    let apiKey: String
    var width: CGFloat? = nil
    @Environment(\.imageCache) private var imageCache
    @Environment(ThemeManager.self) private var themeManager
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(themeManager.current.surfaceColor)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundStyle(themeManager.current.foregroundColor.opacity(0.25))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(performer.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeManager.current.foregroundColor)
                .lineLimit(1)

            if let count = performer.scene_count {
                Text("\(count) scene\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
        .task(id: performer.id) {
            guard let url = performer.imageURL(apiKey: apiKey) else { return }
            image = try? await imageCache.image(for: url)
        }
    }
}

// MARK: - Country flag helper

extension String {
    /// Treats a 2-letter ISO 3166-1 country code as a flag emoji; otherwise returns the string unchanged.
    var countryFlag: String {
        let code = trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isLetter }) else { return self }
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in code.unicodeScalars {
            if let s = UnicodeScalar(base + scalar.value - 65) { flag.unicodeScalars.append(s) }
        }
        return flag.isEmpty ? self : flag
    }
}
