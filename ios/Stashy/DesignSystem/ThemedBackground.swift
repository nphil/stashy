import SwiftUI

/// The app-wide themed background: a static `MeshGradient` built from the active palette's own tokens,
/// giving gentle depth without biasing toward black. Corners lift toward `elevatedSurface` (which blends
/// toward the light `foreground`, so on dark palettes the mesh reads *lighter* than the base — depth, never
/// a slide toward black), with a faint accent glow top-right and a faint secondary glow bottom-left; the
/// centre stays on the base colour so content contrast is preserved.
///
/// One GPU-rendered layer behind content. Its `body` reads only `themeManager.current`, so it re-renders on
/// a theme change and nothing else — it never re-evaluates while scrolling, keeping the scroll path clean.
struct ThemedBackground: View {
    @Environment(ThemeManager.self) private var themeManager

    /// `MeshGradient` is backed by a retained render layer. A long-lived off-screen tab (notably the
    /// Scenes `NavigationStack`) can otherwise bring that old layer back after the palette changed while
    /// another tab was active. Tie identity only to inputs that alter the mesh so SwiftUI replaces the
    /// stale layer on a theme/tuning change, while retaining the exact same static layer during scrolling.
    private struct RenderIdentity: Hashable {
        let theme: AppTheme
        let vibrancy: Double
        let lift: Double
    }

    /// Regular 3×3 control grid (row-major, unit square) — matches the row-major order of `meshColors`.
    private static let points: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),   SIMD2<Float>(0.5, 0),   SIMD2<Float>(1, 0),
        SIMD2<Float>(0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1, 0.5),
        SIMD2<Float>(0, 1),   SIMD2<Float>(0.5, 1),   SIMD2<Float>(1, 1),
    ]

    var body: some View {
        let theme = themeManager.current
        let vibrancy = themeManager.currentMeshVibrancy
        let lift = themeManager.currentMeshLift
        // Every parameter passed explicitly — MeshGradient's initializer exposes no reliable defaults.
        // Vibrancy/lift come from the active palette's variant, tunable in Settings → Background depth.
        MeshGradient(
            width: 3,
            height: 3,
            points: Self.points,
            colors: theme.meshColors(vibrancy: vibrancy, lift: lift),
            background: theme.backgroundColor,
            smoothsColors: true,
            colorSpace: .perceptual
        )
        .id(RenderIdentity(theme: theme, vibrancy: vibrancy, lift: lift))
    }
}

extension View {
    /// Places the themed mesh background behind this view, full-bleed. Drop-in replacement for the old
    /// `.background(theme.backgroundColor.ignoresSafeArea())`.
    func themedBackground() -> some View {
        background(ThemedBackground().ignoresSafeArea())
    }
}
