import SwiftUI

// MARK: - Color helpers

extension Color {
    init(h: Double, s: Double, l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hPrime {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        case 5..<6: (r1, g1, b1) = (c, 0, x)
        default:    (r1, g1, b1) = (0, 0, 0)
        }
        self.init(red: r1 + m, green: g1 + m, blue: b1 + m)
    }

    init(hex: String) {
        var rgb: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}

// MARK: - Theme colors

struct ThemeColors {
    let background: Color
    let foreground: Color
    let primary: Color
    let accent: Color
    let backgroundLightness: Double

    var preferredColorScheme: ColorScheme { backgroundLightness > 0.5 ? .light : .dark }
}

// MARK: - App themes

enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    case stash
    case light, dark
    case forest, garden, emerald, aqua, ocean
    case night, dracula, synthwave, halloween, coffee, business, luxury, black
    case cupcake, valentine, pastel, fantasy, retro, bumblebee, lemonade
    case corporate, cmyk, autumn, winter, acid, cyberpunk, wireframe, lofi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .stash:     return "Stash"
        case .light:     return "Light"
        case .dark:      return "Dark"
        case .forest:    return "Forest"
        case .garden:    return "Garden"
        case .emerald:   return "Emerald"
        case .aqua:      return "Aqua"
        case .ocean:     return "Ocean"
        case .night:     return "Night"
        case .dracula:   return "Dracula"
        case .synthwave: return "Synthwave"
        case .halloween: return "Halloween"
        case .coffee:    return "Coffee"
        case .business:  return "Business"
        case .luxury:    return "Luxury"
        case .black:     return "Black"
        case .cupcake:   return "Cupcake"
        case .valentine: return "Valentine"
        case .pastel:    return "Pastel"
        case .fantasy:   return "Fantasy"
        case .retro:     return "Retro"
        case .bumblebee: return "Bumblebee"
        case .lemonade:  return "Lemonade"
        case .corporate: return "Corporate"
        case .cmyk:      return "CMYK"
        case .autumn:    return "Autumn"
        case .winter:    return "Winter"
        case .acid:      return "Acid"
        case .cyberpunk: return "Cyberpunk"
        case .wireframe: return "Wireframe"
        case .lofi:      return "Lofi"
        }
    }

    var colors: ThemeColors {
        func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
            Color(h: h, s: s / 100, l: l / 100)
        }
        switch self {
        case .stash:     return ThemeColors(background: hsl(0, 0, 8),    foreground: hsl(0, 0, 90),   primary: hsl(4, 73, 48),    accent: hsl(4, 60, 35),    backgroundLightness: 0.08)
        case .light:     return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(215, 28, 17),primary: hsl(259, 94, 51),  accent: hsl(314, 100, 47), backgroundLightness: 1.00)
        case .dark:      return ThemeColors(background: hsl(0, 0, 11),   foreground: hsl(0, 0, 90),   primary: hsl(259, 94, 70),  accent: hsl(314, 100, 70), backgroundLightness: 0.11)
        case .forest:    return ThemeColors(background: hsl(0, 12, 8),   foreground: hsl(0, 12, 82),  primary: hsl(141, 72, 42),  accent: hsl(141, 75, 48),  backgroundLightness: 0.08)
        case .garden:    return ThemeColors(background: hsl(0, 4, 91),   foreground: hsl(0, 3, 6),    primary: hsl(139, 16, 43),  accent: hsl(97, 37, 93),   backgroundLightness: 0.91)
        case .emerald:   return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(219, 20, 25),primary: hsl(141, 50, 60),  accent: hsl(219, 96, 60),  backgroundLightness: 1.00)
        case .aqua:      return ThemeColors(background: hsl(219, 53, 43),foreground: hsl(218, 100, 89),primary: hsl(182, 93, 49), accent: hsl(274, 31, 57),  backgroundLightness: 0.43)
        case .ocean:     return ThemeColors(background: hsl(207, 50, 14),foreground: hsl(207, 30, 90),primary: hsl(199, 89, 64),  accent: hsl(259, 50, 67),  backgroundLightness: 0.14)
        case .night:     return ThemeColors(background: hsl(222, 47, 11),foreground: hsl(222, 65, 82),primary: hsl(198, 93, 60),  accent: hsl(234, 89, 74),  backgroundLightness: 0.11)
        case .dracula:   return ThemeColors(background: hsl(231, 15, 18),foreground: hsl(60, 30, 96), primary: hsl(326, 100, 74), accent: hsl(265, 89, 78),  backgroundLightness: 0.18)
        case .synthwave: return ThemeColors(background: hsl(254, 59, 26),foreground: hsl(260, 60, 98),primary: hsl(321, 70, 69),  accent: hsl(197, 87, 65),  backgroundLightness: 0.26)
        case .halloween: return ThemeColors(background: hsl(0, 0, 13),   foreground: hsl(0, 0, 83),   primary: hsl(32, 89, 52),   accent: hsl(271, 46, 42),  backgroundLightness: 0.13)
        case .coffee:    return ThemeColors(background: hsl(306, 19, 11),foreground: hsl(37, 30, 70), primary: hsl(30, 67, 58),   accent: hsl(182, 25, 50),  backgroundLightness: 0.11)
        case .business:  return ThemeColors(background: hsl(0, 0, 13),   foreground: hsl(0, 0, 82),   primary: hsl(210, 64, 55),  accent: hsl(200, 13, 65),  backgroundLightness: 0.13)
        case .luxury:    return ThemeColors(background: hsl(240, 10, 4), foreground: hsl(37, 67, 58), primary: hsl(0, 0, 100),    accent: hsl(218, 54, 50),  backgroundLightness: 0.04)
        case .black:     return ThemeColors(background: hsl(0, 0, 0),    foreground: hsl(0, 0, 80),   primary: hsl(0, 0, 70),     accent: hsl(0, 0, 50),     backgroundLightness: 0.00)
        case .cupcake:   return ThemeColors(background: hsl(24, 33, 97), foreground: hsl(280, 46, 14),primary: hsl(183, 47, 59),  accent: hsl(338, 71, 78),  backgroundLightness: 0.97)
        case .valentine: return ThemeColors(background: hsl(318, 46, 89),foreground: hsl(344, 38, 28),primary: hsl(353, 74, 67),  accent: hsl(254, 86, 77),  backgroundLightness: 0.89)
        case .pastel:    return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(284, 22, 70),  accent: hsl(352, 70, 80),  backgroundLightness: 1.00)
        case .fantasy:   return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(215, 28, 17),primary: hsl(296, 83, 35),  accent: hsl(200, 100, 37), backgroundLightness: 1.00)
        case .retro:     return ThemeColors(background: hsl(45, 47, 80), foreground: hsl(345, 5, 15), primary: hsl(3, 60, 55),    accent: hsl(145, 35, 50),  backgroundLightness: 0.80)
        case .bumblebee: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(41, 74, 53),   accent: hsl(50, 94, 58),   backgroundLightness: 1.00)
        case .lemonade:  return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(89, 96, 31),   accent: hsl(60, 81, 45),   backgroundLightness: 1.00)
        case .corporate: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(233, 27, 13),primary: hsl(229, 96, 64),  accent: hsl(215, 26, 59),  backgroundLightness: 1.00)
        case .cmyk:      return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(203, 83, 60),  accent: hsl(335, 78, 60),  backgroundLightness: 1.00)
        case .autumn:    return ThemeColors(background: hsl(0, 0, 95),   foreground: hsl(0, 0, 19),   primary: hsl(344, 96, 38),  accent: hsl(0, 63, 50),    backgroundLightness: 0.95)
        case .winter:    return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(214, 30, 32),primary: hsl(212, 100, 51), accent: hsl(247, 47, 43),  backgroundLightness: 1.00)
        case .acid:      return ThemeColors(background: hsl(0, 0, 98),   foreground: hsl(0, 0, 20),   primary: hsl(303, 90, 45),  accent: hsl(27, 100, 50),  backgroundLightness: 0.98)
        case .cyberpunk: return ThemeColors(background: hsl(56, 100, 50),foreground: hsl(56, 100, 10),primary: hsl(345, 100, 50), accent: hsl(195, 80, 55),  backgroundLightness: 0.50)
        case .wireframe: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(0, 0, 40),     accent: hsl(0, 0, 60),     backgroundLightness: 1.00)
        case .lofi:      return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 0),    primary: hsl(0, 0, 5),      accent: hsl(0, 2, 30),     backgroundLightness: 1.00)
        }
    }

    var backgroundColor: Color { colors.background }
    var foregroundColor: Color { colors.foreground }
    var accentColor: Color { colors.primary }
    var secondaryColor: Color { colors.accent }
    var preferredColorScheme: ColorScheme { colors.preferredColorScheme }
}

// MARK: - Theme manager

@Observable
@MainActor
final class ThemeManager {
    private(set) var current: AppTheme {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "stashy.theme") }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "stashy.theme"),
           let saved = AppTheme(rawValue: raw) {
            current = saved
        } else {
            current = .stash
        }
    }

    func set(_ theme: AppTheme) { current = theme }
}

// MARK: - Theme swatch

struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.backgroundColor)
                        .frame(width: 48, height: 48)
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 22, height: 22)
                        .offset(x: -6, y: -2)
                    Circle()
                        .fill(theme.secondaryColor)
                        .frame(width: 14, height: 14)
                        .offset(x: 9, y: 6)
                    if isSelected {
                        Circle()
                            .stroke(theme.accentColor, lineWidth: 3)
                            .frame(width: 52, height: 52)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.accentColor)
                            .background(
                                Circle().fill(theme.backgroundColor).frame(width: 18, height: 18)
                            )
                            .offset(x: 16, y: 16)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(theme.foregroundColor.opacity(0.15), lineWidth: 1)
                        .frame(width: 48, height: 48)
                )
                Text(theme.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }
}
