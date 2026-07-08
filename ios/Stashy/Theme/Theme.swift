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
    // Dark (15)
    case stash, black, midnight, nord, dracula, synthwave, catppuccin, forest
    case monokai, gruvbox, crimson, ember, luxury, ocean, halloween
    // Light (15)
    case light, wireframe, sandstone, cream, cupcake, rosewater, autumn, apricot
    case lemonade, mint, sage, sky, lavender, seafoam, retro

    var id: String { rawValue }

    /// Display name — capitalised raw value, with a couple of stylised exceptions.
    var name: String { rawValue.capitalized }

    /// Light vs dark, from the background lightness — groups the picker and drives the System-mode pairing.
    enum Variant { case light, dark }
    var variant: Variant { colors.backgroundLightness > 0.5 ? .light : .dark }

    var colors: ThemeColors {
        func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
            Color(h: h, s: s / 100, l: l / 100)
        }
        switch self {
        // Dark
        case .stash: return ThemeColors(background: hsl(0, 0, 8),    foreground: hsl(0, 0, 90),   primary: hsl(4, 73, 48),    accent: hsl(4, 60, 35),    backgroundLightness: 0.08)
        case .black: return ThemeColors(background: hsl(0, 0, 0),    foreground: hsl(0, 0, 80),   primary: hsl(0, 0, 70),     accent: hsl(0, 0, 50),     backgroundLightness: 0.00)
        case .midnight: return ThemeColors(background: hsl(222, 40, 7), foreground: hsl(220, 30, 88),primary: hsl(210, 90, 62),  accent: hsl(265, 80, 72),  backgroundLightness: 0.07)
        case .nord: return ThemeColors(background: hsl(220, 16, 22),foreground: hsl(219, 28, 88),primary: hsl(213, 40, 58),  accent: hsl(179, 30, 58),  backgroundLightness: 0.22)
        case .dracula: return ThemeColors(background: hsl(231, 15, 18),foreground: hsl(60, 30, 96), primary: hsl(326, 100, 74), accent: hsl(265, 89, 78),  backgroundLightness: 0.18)
        case .synthwave: return ThemeColors(background: hsl(254, 59, 26),foreground: hsl(260, 60, 98),primary: hsl(321, 70, 69),  accent: hsl(197, 87, 65),  backgroundLightness: 0.26)
        case .catppuccin: return ThemeColors(background: hsl(240, 21, 15),foreground: hsl(226, 64, 88),primary: hsl(267, 84, 81),  accent: hsl(189, 71, 73),  backgroundLightness: 0.15)
        case .forest: return ThemeColors(background: hsl(0, 12, 8),   foreground: hsl(0, 12, 82),  primary: hsl(141, 72, 42),  accent: hsl(141, 75, 48),  backgroundLightness: 0.08)
        case .monokai: return ThemeColors(background: hsl(70, 8, 15),  foreground: hsl(60, 30, 92), primary: hsl(81, 60, 50),   accent: hsl(330, 80, 62),  backgroundLightness: 0.15)
        case .gruvbox: return ThemeColors(background: hsl(20, 10, 16), foreground: hsl(43, 40, 84), primary: hsl(24, 85, 55),   accent: hsl(61, 50, 50),   backgroundLightness: 0.16)
        case .crimson: return ThemeColors(background: hsl(0, 25, 9),   foreground: hsl(0, 10, 88),  primary: hsl(348, 83, 60),  accent: hsl(20, 80, 58),   backgroundLightness: 0.09)
        case .ember: return ThemeColors(background: hsl(20, 20, 10), foreground: hsl(30, 30, 85), primary: hsl(18, 90, 57),   accent: hsl(43, 90, 57),   backgroundLightness: 0.10)
        case .luxury: return ThemeColors(background: hsl(240, 10, 4), foreground: hsl(37, 67, 58), primary: hsl(0, 0, 100),    accent: hsl(218, 54, 50),  backgroundLightness: 0.04)
        case .ocean: return ThemeColors(background: hsl(207, 50, 14),foreground: hsl(207, 30, 90),primary: hsl(199, 89, 64),  accent: hsl(259, 50, 67),  backgroundLightness: 0.14)
        case .halloween: return ThemeColors(background: hsl(0, 0, 13),   foreground: hsl(0, 0, 83),   primary: hsl(32, 89, 52),   accent: hsl(271, 46, 42),  backgroundLightness: 0.13)
        // Light
        case .light: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(215, 28, 17),primary: hsl(259, 94, 51),  accent: hsl(314, 100, 47), backgroundLightness: 1.00)
        case .wireframe: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(0, 0, 40),     accent: hsl(0, 0, 60),     backgroundLightness: 1.00)
        case .sandstone: return ThemeColors(background: hsl(38, 35, 94), foreground: hsl(28, 25, 22), primary: hsl(25, 70, 50),   accent: hsl(200, 40, 45),  backgroundLightness: 0.94)
        case .cream: return ThemeColors(background: hsl(48, 60, 96), foreground: hsl(40, 25, 22), primary: hsl(35, 75, 50),   accent: hsl(160, 35, 45),  backgroundLightness: 0.96)
        case .cupcake: return ThemeColors(background: hsl(24, 33, 97), foreground: hsl(280, 46, 14),primary: hsl(183, 47, 59),  accent: hsl(338, 71, 78),  backgroundLightness: 0.97)
        case .rosewater: return ThemeColors(background: hsl(350, 50, 97),foreground: hsl(345, 25, 25),primary: hsl(345, 70, 62),  accent: hsl(280, 45, 60),  backgroundLightness: 0.97)
        case .autumn: return ThemeColors(background: hsl(0, 0, 95),   foreground: hsl(0, 0, 19),   primary: hsl(344, 96, 38),  accent: hsl(0, 63, 50),    backgroundLightness: 0.95)
        case .apricot: return ThemeColors(background: hsl(30, 80, 95), foreground: hsl(20, 35, 25), primary: hsl(22, 85, 55),   accent: hsl(340, 60, 62),  backgroundLightness: 0.95)
        case .lemonade: return ThemeColors(background: hsl(0, 0, 100),  foreground: hsl(0, 0, 20),   primary: hsl(89, 96, 31),   accent: hsl(60, 81, 45),   backgroundLightness: 1.00)
        case .mint: return ThemeColors(background: hsl(150, 40, 96),foreground: hsl(160, 25, 20),primary: hsl(160, 60, 40),  accent: hsl(190, 55, 45),  backgroundLightness: 0.96)
        case .sage: return ThemeColors(background: hsl(100, 20, 94),foreground: hsl(120, 15, 22),primary: hsl(120, 35, 40),  accent: hsl(40, 45, 50),   backgroundLightness: 0.94)
        case .sky: return ThemeColors(background: hsl(205, 60, 97),foreground: hsl(215, 30, 25),primary: hsl(205, 80, 52),  accent: hsl(255, 60, 60),  backgroundLightness: 0.97)
        case .lavender: return ThemeColors(background: hsl(265, 45, 97),foreground: hsl(270, 25, 28),primary: hsl(265, 60, 62),  accent: hsl(320, 50, 64),  backgroundLightness: 0.97)
        case .seafoam: return ThemeColors(background: hsl(170, 45, 95),foreground: hsl(185, 30, 20),primary: hsl(175, 55, 42),  accent: hsl(200, 60, 50),  backgroundLightness: 0.95)
        case .retro: return ThemeColors(background: hsl(45, 47, 80), foreground: hsl(345, 5, 15), primary: hsl(3, 60, 55),    accent: hsl(145, 35, 50),  backgroundLightness: 0.80)
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
        darkTheme  = AppTheme(rawValue: d.string(forKey: "stashy.theme.dark")  ?? "") ?? .midnight
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

// MARK: - Theme chrome (UIKit appearance)

/// Applies the active palette to UIKit-backed chrome that SwiftUI doesn't reach through view modifiers —
/// primarily the navigation bar (background, title, and bar-button tint). Called at launch and whenever the
/// theme changes so pushed screens adopt the palette. (The tab bar is themed directly in `LibraryView` via
/// `toolbarBackground`, and list surfaces via `scrollContentBackground` — both reactive.)
enum ThemeChrome {
    static func apply(_ theme: AppTheme) {
        let bg = UIColor(theme.backgroundColor)
        let fg = UIColor(theme.foregroundColor)
        let accent = UIColor(theme.accentColor)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = UIColor(theme.foregroundColor.opacity(0.12))
        nav.titleTextAttributes = [.foregroundColor: fg]
        nav.largeTitleTextAttributes = [.foregroundColor: fg]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.foregroundColor: accent]
        nav.buttonAppearance = button
        nav.doneButtonAppearance = button

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = nav
        proxy.compactAppearance = nav
        proxy.scrollEdgeAppearance = nav
        proxy.tintColor = accent
    }
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
