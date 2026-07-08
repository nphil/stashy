import SwiftUI
import UIKit

// MARK: - Color helpers

extension Color {
    /// Linearly blends toward `other` by `fraction` (0…1). Used to derive elevated surfaces from the theme background.
    func blended(with other: Color, fraction: Double) -> Color {
        let f = CGFloat(max(0, min(1, fraction)))
        let c1 = UIColor(self)
        let c2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: Double(r1 + (r2 - r1) * f),
            green: Double(g1 + (g2 - g1) * f),
            blue: Double(b1 + (b2 - b1) * f)
        )
    }

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

    /// Card/row surface, nudged slightly off the background toward the foreground.
    var surface: Color { background.blended(with: foreground, fraction: 0.07) }
    /// A more elevated surface for stacked/secondary content.
    var elevatedSurface: Color { background.blended(with: foreground, fraction: 0.13) }
}

// MARK: - App themes

enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    case stash
    case light, dark
    case forest, garden, emerald, aqua, ocean
    case night, dracula, synthwave, halloween, coffee, business, luxury, black
    case cupcake, valentine, pastel, fantasy, retro, bumblebee, lemonade
    case corporate, cmyk, autumn, winter, acid, cyberpunk, wireframe, lofi
    // Additional dark palettes
    case midnight, obsidian, nord, gruvbox, monokai, tokyo, catppuccin, crimson
    case ember, slate, mocha, plum, carbon, matrix, steel
    // Additional light palettes
    case sandstone, linen, mint, rosewater, sky, sepia, cream, sage
    case blush, porcelain, meadow, apricot, lavender, seafoam, parchment

    var id: String { rawValue }

    /// Display name — capitalised raw value, with a couple of stylised exceptions.
    var name: String {
        switch self {
        case .cmyk:  return "CMYK"
        case .tokyo: return "Tokyo Night"
        default:     return rawValue.capitalized
        }
    }

    /// Light vs dark, from the background lightness — groups the picker and drives the System-mode pairing.
    enum Variant { case light, dark }
    var variant: Variant { colors.backgroundLightness > 0.5 ? .light : .dark }

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
        // Additional dark palettes
        case .midnight:  return ThemeColors(background: hsl(222, 40, 7), foreground: hsl(220, 30, 88),primary: hsl(210, 90, 62),  accent: hsl(265, 80, 72),  backgroundLightness: 0.07)
        case .obsidian:  return ThemeColors(background: hsl(260, 15, 9), foreground: hsl(260, 10, 85),primary: hsl(280, 70, 68),  accent: hsl(190, 80, 60),  backgroundLightness: 0.09)
        case .nord:      return ThemeColors(background: hsl(220, 16, 22),foreground: hsl(219, 28, 88),primary: hsl(213, 40, 58),  accent: hsl(179, 30, 58),  backgroundLightness: 0.22)
        case .gruvbox:   return ThemeColors(background: hsl(20, 10, 16), foreground: hsl(43, 40, 84), primary: hsl(24, 85, 55),   accent: hsl(61, 50, 50),   backgroundLightness: 0.16)
        case .monokai:   return ThemeColors(background: hsl(70, 8, 15),  foreground: hsl(60, 30, 92), primary: hsl(81, 60, 50),   accent: hsl(330, 80, 62),  backgroundLightness: 0.15)
        case .tokyo:     return ThemeColors(background: hsl(235, 25, 15),foreground: hsl(230, 40, 86),primary: hsl(220, 90, 68),  accent: hsl(280, 70, 72),  backgroundLightness: 0.15)
        case .catppuccin:return ThemeColors(background: hsl(240, 21, 15),foreground: hsl(226, 64, 88),primary: hsl(267, 84, 81),  accent: hsl(189, 71, 73),  backgroundLightness: 0.15)
        case .crimson:   return ThemeColors(background: hsl(0, 25, 9),   foreground: hsl(0, 10, 88),  primary: hsl(348, 83, 60),  accent: hsl(20, 80, 58),   backgroundLightness: 0.09)
        case .ember:     return ThemeColors(background: hsl(20, 20, 10), foreground: hsl(30, 30, 85), primary: hsl(18, 90, 57),   accent: hsl(43, 90, 57),   backgroundLightness: 0.10)
        case .slate:     return ThemeColors(background: hsl(215, 20, 17),foreground: hsl(214, 20, 84),primary: hsl(200, 70, 60),  accent: hsl(160, 45, 56),  backgroundLightness: 0.17)
        case .mocha:     return ThemeColors(background: hsl(25, 18, 12), foreground: hsl(30, 25, 82), primary: hsl(28, 55, 57),   accent: hsl(160, 30, 52),  backgroundLightness: 0.12)
        case .plum:      return ThemeColors(background: hsl(290, 25, 12),foreground: hsl(300, 20, 86),primary: hsl(320, 70, 70),  accent: hsl(260, 65, 72),  backgroundLightness: 0.12)
        case .carbon:    return ThemeColors(background: hsl(0, 0, 10),   foreground: hsl(0, 0, 82),   primary: hsl(199, 80, 57),  accent: hsl(0, 0, 55),     backgroundLightness: 0.10)
        case .matrix:    return ThemeColors(background: hsl(120, 20, 6), foreground: hsl(120, 40, 80),primary: hsl(135, 80, 47),  accent: hsl(90, 60, 52),   backgroundLightness: 0.06)
        case .steel:     return ThemeColors(background: hsl(210, 12, 20),foreground: hsl(210, 15, 85),primary: hsl(205, 55, 62),  accent: hsl(30, 60, 62),   backgroundLightness: 0.20)
        // Additional light palettes
        case .sandstone: return ThemeColors(background: hsl(38, 35, 94), foreground: hsl(28, 25, 22), primary: hsl(25, 70, 50),   accent: hsl(200, 40, 45),  backgroundLightness: 0.94)
        case .linen:     return ThemeColors(background: hsl(30, 25, 96), foreground: hsl(30, 15, 25), primary: hsl(15, 55, 52),   accent: hsl(180, 30, 45),  backgroundLightness: 0.96)
        case .mint:      return ThemeColors(background: hsl(150, 40, 96),foreground: hsl(160, 25, 20),primary: hsl(160, 60, 40),  accent: hsl(190, 55, 45),  backgroundLightness: 0.96)
        case .rosewater: return ThemeColors(background: hsl(350, 50, 97),foreground: hsl(345, 25, 25),primary: hsl(345, 70, 62),  accent: hsl(280, 45, 60),  backgroundLightness: 0.97)
        case .sky:       return ThemeColors(background: hsl(205, 60, 97),foreground: hsl(215, 30, 25),primary: hsl(205, 80, 52),  accent: hsl(255, 60, 60),  backgroundLightness: 0.97)
        case .sepia:     return ThemeColors(background: hsl(40, 40, 92), foreground: hsl(30, 30, 20), primary: hsl(28, 60, 44),   accent: hsl(15, 50, 47),   backgroundLightness: 0.92)
        case .cream:     return ThemeColors(background: hsl(48, 60, 96), foreground: hsl(40, 25, 22), primary: hsl(35, 75, 50),   accent: hsl(160, 35, 45),  backgroundLightness: 0.96)
        case .sage:      return ThemeColors(background: hsl(100, 20, 94),foreground: hsl(120, 15, 22),primary: hsl(120, 35, 40),  accent: hsl(40, 45, 50),   backgroundLightness: 0.94)
        case .blush:     return ThemeColors(background: hsl(340, 50, 96),foreground: hsl(330, 20, 25),primary: hsl(335, 65, 64),  accent: hsl(20, 70, 64),   backgroundLightness: 0.96)
        case .porcelain: return ThemeColors(background: hsl(210, 20, 98),foreground: hsl(215, 25, 22),primary: hsl(220, 70, 55),  accent: hsl(190, 50, 50),  backgroundLightness: 0.98)
        case .meadow:    return ThemeColors(background: hsl(90, 35, 95), foreground: hsl(110, 25, 20),primary: hsl(130, 50, 40),  accent: hsl(75, 60, 45),   backgroundLightness: 0.95)
        case .apricot:   return ThemeColors(background: hsl(30, 80, 95), foreground: hsl(20, 35, 25), primary: hsl(22, 85, 55),   accent: hsl(340, 60, 62),  backgroundLightness: 0.95)
        case .lavender:  return ThemeColors(background: hsl(265, 45, 97),foreground: hsl(270, 25, 28),primary: hsl(265, 60, 62),  accent: hsl(320, 50, 64),  backgroundLightness: 0.97)
        case .seafoam:   return ThemeColors(background: hsl(170, 45, 95),foreground: hsl(185, 30, 20),primary: hsl(175, 55, 42),  accent: hsl(200, 60, 50),  backgroundLightness: 0.95)
        case .parchment: return ThemeColors(background: hsl(45, 45, 93), foreground: hsl(35, 30, 22), primary: hsl(30, 55, 45),   accent: hsl(210, 35, 45),  backgroundLightness: 0.93)
        }
    }

    var backgroundColor: Color { colors.background }
    var foregroundColor: Color { colors.foreground }
    var accentColor: Color { colors.primary }
    var secondaryColor: Color { colors.accent }
    var surfaceColor: Color { colors.surface }
    var elevatedSurfaceColor: Color { colors.elevatedSurface }
    var preferredColorScheme: ColorScheme { colors.preferredColorScheme }
}

// MARK: - Theme manager

@Observable
@MainActor
final class ThemeManager {
    /// The palette used when NOT in system mode (a directly-picked theme).
    private(set) var fixedTheme: AppTheme
    /// System (auto) mode: follow the OS appearance, using `lightTheme` when the system is light and
    /// `darkTheme` when it's dark.
    private(set) var systemMode: Bool
    private(set) var lightTheme: AppTheme
    private(set) var darkTheme: AppTheme
    /// Whether the OS is currently dark — fed from the root view's `colorScheme`. Only used in system mode.
    var systemIsDark: Bool = UITraitCollection.current.userInterfaceStyle == .dark

    /// The resolved, active theme that the whole app reads.
    var current: AppTheme { systemMode ? (systemIsDark ? darkTheme : lightTheme) : fixedTheme }

    /// Force the fixed theme's light/dark scheme when manual; follow the OS (nil) in system mode.
    var enforcedColorScheme: ColorScheme? { systemMode ? nil : fixedTheme.preferredColorScheme }

    init() {
        let d = UserDefaults.standard
        fixedTheme = AppTheme(rawValue: d.string(forKey: "stashy.theme") ?? "") ?? .stash
        systemMode = d.bool(forKey: "stashy.theme.system")
        lightTheme = AppTheme(rawValue: d.string(forKey: "stashy.theme.light") ?? "") ?? .light
        darkTheme  = AppTheme(rawValue: d.string(forKey: "stashy.theme.dark")  ?? "") ?? .dark
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(fixedTheme.rawValue, forKey: "stashy.theme")
        d.set(systemMode, forKey: "stashy.theme.system")
        d.set(lightTheme.rawValue, forKey: "stashy.theme.light")
        d.set(darkTheme.rawValue, forKey: "stashy.theme.dark")
    }

    /// Pick a palette directly — turns system mode off.
    func set(_ theme: AppTheme) { fixedTheme = theme; systemMode = false; persist() }
    func setSystemMode(_ on: Bool) { systemMode = on; persist() }
    func setLight(_ theme: AppTheme) { lightTheme = theme; persist() }
    func setDark(_ theme: AppTheme) { darkTheme = theme; persist() }
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
