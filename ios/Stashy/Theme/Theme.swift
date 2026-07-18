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

    /// 3×3 mesh-gradient colours (row-major) for the themed background depth. A calm, gently-lifted base
    /// (centre + edges) with the accent (`primary`) and secondary (`accent`) hues glowing in the corners as
    /// a diagonal two-tone. `vibrancy` = how strongly those hues tint the corners; `lift` = how far the base
    /// rises toward the light `foreground` (so dark palettes read lighter — depth, never toward black — and
    /// light palettes stay softly tinted). Both are user-tunable per light/dark in Settings → Background depth.
    func meshColors(vibrancy: Double, lift: Double) -> [Color] {
        let calm  = background.blended(with: foreground, fraction: lift * 0.4)
        let glowP = background.blended(with: primary,    fraction: vibrancy)
        let glowS = background.blended(with: accent,     fraction: vibrancy * 0.9)
        return [
            glowP, calm, glowS,
            calm,  calm, calm,
            glowS, calm, glowP,
        ]
    }
}

// MARK: - App themes

enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    // Dark (8) — deep, colourful backgrounds (never near-black) with vibrant accents.
    case nocturne, aurora, synthwave, ember, verdant, ruby, slate, mocha
    // Light (6) — softly tinted backgrounds (never pure white) with vibrant accents.
    case daybreak, blossom, meadow, citrus, periwinkle, seabreeze

    var id: String { rawValue }

    /// Display name — capitalised raw value.
    var name: String { rawValue.capitalized }

    /// Light vs dark, from the background lightness — groups the picker and drives the System-mode pairing.
    enum Variant { case light, dark }
    var variant: Variant { colors.backgroundLightness > 0.5 ? .light : .dark }

    var colors: ThemeColors {
        func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
            Color(h: h, s: s / 100, l: l / 100)
        }
        switch self {
        // Dark — deep, colourful backgrounds with vibrant accents.
        case .nocturne:   return ThemeColors(background: hsl(230, 42, 13), foreground: hsl(220, 40, 90), primary: hsl(214, 90, 63), accent: hsl(266, 85, 72), backgroundLightness: 0.13)
        case .aurora:     return ThemeColors(background: hsl(188, 42, 12), foreground: hsl(180, 30, 90), primary: hsl(165, 72, 52), accent: hsl(198, 82, 60), backgroundLightness: 0.12)
        case .synthwave:  return ThemeColors(background: hsl(276, 46, 14), foreground: hsl(280, 45, 93), primary: hsl(322, 88, 66), accent: hsl(190, 90, 60), backgroundLightness: 0.14)
        case .ember:      return ThemeColors(background: hsl(16, 42, 12),  foreground: hsl(28, 45, 90),  primary: hsl(22, 92, 58),  accent: hsl(43, 95, 60),  backgroundLightness: 0.12)
        case .verdant:    return ThemeColors(background: hsl(150, 38, 11), foreground: hsl(120, 25, 90), primary: hsl(140, 65, 50), accent: hsl(80, 70, 55),  backgroundLightness: 0.11)
        case .ruby:       return ThemeColors(background: hsl(344, 42, 13), foreground: hsl(350, 40, 92), primary: hsl(348, 85, 64), accent: hsl(18, 88, 62),  backgroundLightness: 0.13)
        case .slate:      return ThemeColors(background: hsl(220, 22, 16), foreground: hsl(215, 25, 90), primary: hsl(205, 88, 62), accent: hsl(172, 62, 52), backgroundLightness: 0.16)
        case .mocha:      return ThemeColors(background: hsl(25, 28, 13),  foreground: hsl(30, 25, 88),  primary: hsl(30, 62, 60),  accent: hsl(160, 42, 55), backgroundLightness: 0.13)
        // Light — softly tinted backgrounds with vibrant accents.
        case .daybreak:   return ThemeColors(background: hsl(214, 45, 95), foreground: hsl(220, 35, 22), primary: hsl(220, 82, 52), accent: hsl(265, 65, 58), backgroundLightness: 0.95)
        case .blossom:    return ThemeColors(background: hsl(348, 52, 96), foreground: hsl(345, 30, 26), primary: hsl(345, 78, 56), accent: hsl(20, 82, 58),  backgroundLightness: 0.96)
        case .meadow:     return ThemeColors(background: hsl(150, 42, 94), foreground: hsl(155, 28, 22), primary: hsl(152, 58, 40), accent: hsl(192, 60, 46), backgroundLightness: 0.94)
        case .citrus:     return ThemeColors(background: hsl(46, 62, 94),  foreground: hsl(30, 35, 24),  primary: hsl(30, 88, 50),  accent: hsl(92, 52, 42),  backgroundLightness: 0.94)
        case .periwinkle: return ThemeColors(background: hsl(252, 45, 96), foreground: hsl(258, 30, 28), primary: hsl(258, 66, 60), accent: hsl(322, 62, 60), backgroundLightness: 0.96)
        case .seabreeze:  return ThemeColors(background: hsl(186, 48, 94), foreground: hsl(195, 35, 22), primary: hsl(190, 75, 44), accent: hsl(220, 70, 56), backgroundLightness: 0.94)
        }
    }

    var backgroundColor: Color { colors.background }
    var foregroundColor: Color { colors.foreground }
    var accentColor: Color { colors.primary }
    var secondaryColor: Color { colors.accent }
    var surfaceColor: Color { colors.surface }
    var elevatedSurfaceColor: Color { colors.elevatedSurface }
    func meshColors(vibrancy: Double, lift: Double) -> [Color] { colors.meshColors(vibrancy: vibrancy, lift: lift) }
    var preferredColorScheme: ColorScheme { colors.preferredColorScheme }
}

// MARK: - Theme manager

/// Bounds + defaults for the user-tunable mesh background. Defaults are the values dialed in during design
/// (Vibrancy 50 / Lift 32); the ranges leave headroom on either side without going garish or washed-out.
enum MeshTuning {
    static let vibrancyRange: ClosedRange<Double> = 0.0 ... 0.65
    static let liftRange: ClosedRange<Double> = 0.0 ... 0.42
    static let defaultVibrancy: Double = 0.50
    static let defaultLift: Double = 0.32
}

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

    /// Mesh-background tuning, stored separately for dark and light palettes (tunable in Settings).
    private(set) var meshVibrancyDark: Double
    private(set) var meshLiftDark: Double
    private(set) var meshVibrancyLight: Double
    private(set) var meshLiftLight: Double

    /// The resolved, active theme that the whole app reads.
    var current: AppTheme { systemMode ? (systemIsDark ? darkTheme : lightTheme) : fixedTheme }

    /// Mesh tuning for the currently-active palette's variant.
    var currentMeshVibrancy: Double { current.variant == .light ? meshVibrancyLight : meshVibrancyDark }
    var currentMeshLift: Double { current.variant == .light ? meshLiftLight : meshLiftDark }

    /// Force the fixed theme's light/dark scheme when manual; follow the OS (nil) in system mode.
    var enforcedColorScheme: ColorScheme? { systemMode ? nil : fixedTheme.preferredColorScheme }

    init() {
        let d = UserDefaults.standard
        fixedTheme = AppTheme(rawValue: d.string(forKey: "stashy.theme") ?? "") ?? .nocturne
        systemMode = d.bool(forKey: "stashy.theme.system")
        lightTheme = AppTheme(rawValue: d.string(forKey: "stashy.theme.light") ?? "") ?? .daybreak
        darkTheme  = AppTheme(rawValue: d.string(forKey: "stashy.theme.dark")  ?? "") ?? .nocturne
        meshVibrancyDark  = (d.object(forKey: "stashy.mesh.vib.dark")   as? Double) ?? MeshTuning.defaultVibrancy
        meshLiftDark      = (d.object(forKey: "stashy.mesh.lift.dark")  as? Double) ?? MeshTuning.defaultLift
        meshVibrancyLight = (d.object(forKey: "stashy.mesh.vib.light")  as? Double) ?? MeshTuning.defaultVibrancy
        meshLiftLight     = (d.object(forKey: "stashy.mesh.lift.light") as? Double) ?? MeshTuning.defaultLift
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(fixedTheme.rawValue, forKey: "stashy.theme")
        d.set(systemMode, forKey: "stashy.theme.system")
        d.set(lightTheme.rawValue, forKey: "stashy.theme.light")
        d.set(darkTheme.rawValue, forKey: "stashy.theme.dark")
    }

    private func persistMesh() {
        let d = UserDefaults.standard
        d.set(meshVibrancyDark, forKey: "stashy.mesh.vib.dark")
        d.set(meshLiftDark, forKey: "stashy.mesh.lift.dark")
        d.set(meshVibrancyLight, forKey: "stashy.mesh.vib.light")
        d.set(meshLiftLight, forKey: "stashy.mesh.lift.light")
    }

    /// Pick a palette directly — turns system mode off.
    func set(_ theme: AppTheme) { fixedTheme = theme; systemMode = false; persist() }
    func setSystemMode(_ on: Bool) { systemMode = on; persist() }
    func setLight(_ theme: AppTheme) { lightTheme = theme; persist() }
    func setDark(_ theme: AppTheme) { darkTheme = theme; persist() }

    func setMeshVibrancy(_ v: Double, dark: Bool) {
        let c = min(max(v, MeshTuning.vibrancyRange.lowerBound), MeshTuning.vibrancyRange.upperBound)
        if dark { meshVibrancyDark = c } else { meshVibrancyLight = c }
        persistMesh()
    }
    func setMeshLift(_ v: Double, dark: Bool) {
        let c = min(max(v, MeshTuning.liftRange.lowerBound), MeshTuning.liftRange.upperBound)
        if dark { meshLiftDark = c } else { meshLiftLight = c }
        persistMesh()
    }
}

// MARK: - Theme chrome (UIKit appearance)

/// Applies the active palette to UIKit-backed chrome that SwiftUI doesn't reach through view modifiers —
/// primarily the navigation bar (background, title, and bar-button tint). Called at launch and whenever the
/// theme changes so pushed screens adopt the palette. (The tab bar is themed directly in `LibraryView` via
/// `toolbarBackground`, and list surfaces via `scrollContentBackground` — both reactive.)
enum ThemeChrome {
    static func apply(_ theme: AppTheme) {
        let fg = UIColor(theme.foregroundColor)
        let accent = UIColor(theme.accentColor)

        // Translucent, NOT opaque: an opaque themed bar killed the native scroll-under-glass
        // ("immersive") look. Standard = system blur (adapts to the enforced light/dark scheme) with
        // themed title/button colors; scroll-edge = fully transparent so the bar disappears at rest and
        // gains glass only once content scrolls behind it. Zero render cost — bar materials are
        // UIKit-native.
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [.foregroundColor: fg]
        nav.largeTitleTextAttributes = [.foregroundColor: fg]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.foregroundColor: accent]
        nav.buttonAppearance = button

        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = [.foregroundColor: fg]
        edge.largeTitleTextAttributes = [.foregroundColor: fg]
        edge.buttonAppearance = button

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = nav
        proxy.compactAppearance = nav
        proxy.scrollEdgeAppearance = edge
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
