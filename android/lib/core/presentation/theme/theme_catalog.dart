import 'package:flutter/material.dart';

/// A named theme in the catalog: a palette family with a light and a dark
/// [ColorScheme] variant. The active [ThemeMode] selects which variant renders,
/// so picking one family themes the whole app in both brightnesses.
///
/// Schemes are built with [ColorScheme.fromSeed] (seeded by the palette's
/// primary) and then have the palette's identity roles pinned on top, so the
/// tonal container tiers stay populated while the recognizable colors are exact.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.name,
    required this.light,
    required this.dark,
    required this.lightRating,
    required this.darkRating,
  });

  /// Stable id persisted in preferences (never localized).
  final String id;

  /// Display name — a proper noun, shown as-is in the picker (not localized).
  final String name;

  final ColorScheme light;
  final ColorScheme dark;

  /// Palette-appropriate rating accent (stars) for each variant.
  final Color lightRating;
  final Color darkRating;
}

/// The curated theme catalog plus the two special selection ids.
class ThemeCatalog {
  ThemeCatalog._();

  /// Selection id meaning "use the free-form seed color" (the classic picker).
  static const String customPresetId = 'custom';

  /// Selection id meaning "derive colors from the device wallpaper" (Android 12+).
  static const String dynamicPresetId = 'dynamic';

  static ThemePreset? byId(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 16 palette families, each with a light and dark variant (32 schemes).
  static final List<ThemePreset> presets = <ThemePreset>[
    _preset('stashy', 'Stashy',
        light: const _Roles(
            primary: 0xFF0F766E, onPrimary: 0xFFFFFFFF, secondary: 0xFF4B7E79,
            tertiary: 0xFFC2624F, surface: 0xFFFBFCFD, surfaceContainer: 0xFFEEF4F3,
            surfaceContainerHigh: 0xFFE2EEEC, onSurface: 0xFF14201F,
            onSurfaceVariant: 0xFF4B5B59, outline: 0xFFD3E0DE, error: 0xFFB3261E,
            rating: 0xFFB7791F),
        dark: const _Roles(
            primary: 0xFF2DD4BF, onPrimary: 0xFF04211D, secondary: 0xFF5EAAA2,
            tertiary: 0xFFE9977A, surface: 0xFF0E1615, surfaceContainer: 0xFF14211F,
            surfaceContainerHigh: 0xFF1C2E2B, onSurface: 0xFFE6F1EF,
            onSurfaceVariant: 0xFF9DB2AE, outline: 0xFF2C3F3C, error: 0xFFF2B8B5,
            rating: 0xFFF6C453)),
    _preset('material', 'Material',
        light: const _Roles(
            primary: 0xFF6750A4, onPrimary: 0xFFFFFFFF, secondary: 0xFF625B71,
            tertiary: 0xFF7D5260, surface: 0xFFFEF7FF, surfaceContainer: 0xFFF3EDF7,
            surfaceContainerHigh: 0xFFE9DEF8, onSurface: 0xFF1D1B20,
            onSurfaceVariant: 0xFF49454F, outline: 0xFFCAC4D0, error: 0xFFB3261E,
            rating: 0xFFB26A00),
        dark: const _Roles(
            primary: 0xFFD0BCFF, onPrimary: 0xFF381E72, secondary: 0xFFCCC2DC,
            tertiary: 0xFFEFB8C8, surface: 0xFF141218, surfaceContainer: 0xFF1D1B20,
            surfaceContainerHigh: 0xFF2B2930, onSurface: 0xFFE6E0E9,
            onSurfaceVariant: 0xFFCAC4D0, outline: 0xFF49454F, error: 0xFFF2B8B5,
            rating: 0xFFFFB868)),
    _preset('nord', 'Nord',
        light: const _Roles(
            primary: 0xFF5E81AC, onPrimary: 0xFFFFFFFF, secondary: 0xFF81A1C1,
            tertiary: 0xFF6E8C5A, surface: 0xFFECEFF4, surfaceContainer: 0xFFE5E9F0,
            surfaceContainerHigh: 0xFFD8DEE9, onSurface: 0xFF2E3440,
            onSurfaceVariant: 0xFF434C5E, outline: 0xFFC2CAD6, error: 0xFFBF616A,
            rating: 0xFFB48A00),
        dark: const _Roles(
            primary: 0xFF88C0D0, onPrimary: 0xFF2E3440, secondary: 0xFF81A1C1,
            tertiary: 0xFFA3BE8C, surface: 0xFF2E3440, surfaceContainer: 0xFF3B4252,
            surfaceContainerHigh: 0xFF434C5E, onSurface: 0xFFECEFF4,
            onSurfaceVariant: 0xFFD8DEE9, outline: 0xFF4C566A, error: 0xFFBF616A,
            rating: 0xFFEBCB8B)),
    _preset('dracula', 'Dracula',
        light: const _Roles(
            primary: 0xFF7C4DBE, onPrimary: 0xFFFFFFFF, secondary: 0xFFC4407F,
            tertiary: 0xFF1B8AA6, surface: 0xFFF5F4F2, surfaceContainer: 0xFFECEBE6,
            surfaceContainerHigh: 0xFFDED9E8, onSurface: 0xFF1F1F28,
            onSurfaceVariant: 0xFF4C4C57, outline: 0xFFCFC9D6, error: 0xFFCB3A2A,
            rating: 0xFFB58900),
        dark: const _Roles(
            primary: 0xFFBD93F9, onPrimary: 0xFF282A36, secondary: 0xFFFF79C6,
            tertiary: 0xFF8BE9FD, surface: 0xFF282A36, surfaceContainer: 0xFF343746,
            surfaceContainerHigh: 0xFF44475A, onSurface: 0xFFF8F8F2,
            onSurfaceVariant: 0xFFBCC0CF, outline: 0xFF4A4D5E, error: 0xFFFF5555,
            rating: 0xFFFFB86C)),
    _preset('catppuccin', 'Catppuccin',
        light: const _Roles(
            primary: 0xFF1E66F5, onPrimary: 0xFFFFFFFF, secondary: 0xFFEA76CB,
            tertiary: 0xFF40A02B, surface: 0xFFEFF1F5, surfaceContainer: 0xFFE6E9EF,
            surfaceContainerHigh: 0xFFDCE0E8, onSurface: 0xFF4C4F69,
            onSurfaceVariant: 0xFF6C6F85, outline: 0xFFBCC0CC, error: 0xFFD20F39,
            rating: 0xFFDF8E1D),
        dark: const _Roles(
            primary: 0xFF89B4FA, onPrimary: 0xFF1E1E2E, secondary: 0xFFF5C2E7,
            tertiary: 0xFFA6E3A1, surface: 0xFF1E1E2E, surfaceContainer: 0xFF313244,
            surfaceContainerHigh: 0xFF45475A, onSurface: 0xFFCDD6F4,
            onSurfaceVariant: 0xFFA6ADC8, outline: 0xFF585B70, error: 0xFFF38BA8,
            rating: 0xFFF9E2AF)),
    _preset('solarized', 'Solarized',
        light: const _Roles(
            primary: 0xFF268BD2, onPrimary: 0xFFFFFFFF, secondary: 0xFF2AA198,
            tertiary: 0xFF859900, surface: 0xFFFDF6E3, surfaceContainer: 0xFFEEE8D5,
            surfaceContainerHigh: 0xFFE3DCC5, onSurface: 0xFF073642,
            onSurfaceVariant: 0xFF657B83, outline: 0xFFD6CFB8, error: 0xFFDC322F,
            rating: 0xFFB58900),
        dark: const _Roles(
            primary: 0xFF268BD2, onPrimary: 0xFF002B36, secondary: 0xFF2AA198,
            tertiary: 0xFF859900, surface: 0xFF002B36, surfaceContainer: 0xFF073642,
            surfaceContainerHigh: 0xFF0B4451, onSurface: 0xFFC4CDCD,
            onSurfaceVariant: 0xFF839496, outline: 0xFF0E4E5C, error: 0xFFDC322F,
            rating: 0xFFB58900)),
    _preset('gruvbox', 'Gruvbox',
        light: const _Roles(
            primary: 0xFFB57614, onPrimary: 0xFFFFFFFF, secondary: 0xFFAF3A03,
            tertiary: 0xFF427B58, surface: 0xFFFBF1C7, surfaceContainer: 0xFFEBDBB2,
            surfaceContainerHigh: 0xFFE4D5A8, onSurface: 0xFF3C3836,
            onSurfaceVariant: 0xFF665C54, outline: 0xFFD5C4A1, error: 0xFF9D0006,
            rating: 0xFFB57614),
        dark: const _Roles(
            primary: 0xFFFABD2F, onPrimary: 0xFF282828, secondary: 0xFFFE8019,
            tertiary: 0xFF8EC07C, surface: 0xFF282828, surfaceContainer: 0xFF3C3836,
            surfaceContainerHigh: 0xFF504945, onSurface: 0xFFEBDBB2,
            onSurfaceVariant: 0xFFBDAE93, outline: 0xFF665C54, error: 0xFFFB4934,
            rating: 0xFFFABD2F)),
    _preset('rose_pine', 'Rosé Pine',
        light: const _Roles(
            primary: 0xFFB4637A, onPrimary: 0xFFFFFFFF, secondary: 0xFF907AA9,
            tertiary: 0xFF56949F, surface: 0xFFFAF4ED, surfaceContainer: 0xFFFFFAF3,
            surfaceContainerHigh: 0xFFF2E9E1, onSurface: 0xFF575279,
            onSurfaceVariant: 0xFF797593, outline: 0xFFDFDAD9, error: 0xFFB4637A,
            rating: 0xFFEA9D34),
        dark: const _Roles(
            primary: 0xFFEBBCBA, onPrimary: 0xFF191724, secondary: 0xFFC4A7E7,
            tertiary: 0xFF9CCFD8, surface: 0xFF191724, surfaceContainer: 0xFF1F1D2E,
            surfaceContainerHigh: 0xFF26233A, onSurface: 0xFFE0DEF4,
            onSurfaceVariant: 0xFF908CAA, outline: 0xFF403D52, error: 0xFFEB6F92,
            rating: 0xFFF6C177)),
    _preset('tokyo_night', 'Tokyo Night',
        light: const _Roles(
            primary: 0xFF2E7DE9, onPrimary: 0xFFFFFFFF, secondary: 0xFF9854F1,
            tertiary: 0xFF007197, surface: 0xFFE1E2E7, surfaceContainer: 0xFFE9E9ED,
            surfaceContainerHigh: 0xFFDADBE0, onSurface: 0xFF3760BF,
            onSurfaceVariant: 0xFF6172B0, outline: 0xFFC4C8DA, error: 0xFFF52A65,
            rating: 0xFF8C6C3E),
        dark: const _Roles(
            primary: 0xFF7AA2F7, onPrimary: 0xFF1A1B26, secondary: 0xFFBB9AF7,
            tertiary: 0xFF7DCFFF, surface: 0xFF1A1B26, surfaceContainer: 0xFF1F2335,
            surfaceContainerHigh: 0xFF292E42, onSurface: 0xFFC0CAF5,
            onSurfaceVariant: 0xFF9AA5CE, outline: 0xFF3B4261, error: 0xFFF7768E,
            rating: 0xFFE0AF68)),
    _preset('everforest', 'Everforest',
        light: const _Roles(
            primary: 0xFF7A8C00, onPrimary: 0xFFFFFFFF, secondary: 0xFF35A77C,
            tertiary: 0xFFDF69BA, surface: 0xFFFDF6E3, surfaceContainer: 0xFFF4F0D9,
            surfaceContainerHigh: 0xFFEFEBD4, onSurface: 0xFF5C6A72,
            onSurfaceVariant: 0xFF829181, outline: 0xFFDDD8BE, error: 0xFFF85552,
            rating: 0xFFDFA000),
        dark: const _Roles(
            primary: 0xFFA7C080, onPrimary: 0xFF2D353B, secondary: 0xFF7FBBB3,
            tertiary: 0xFFD699B6, surface: 0xFF2D353B, surfaceContainer: 0xFF343F44,
            surfaceContainerHigh: 0xFF3D484D, onSurface: 0xFFD3C6AA,
            onSurfaceVariant: 0xFF9DA9A0, outline: 0xFF4F585E, error: 0xFFE67E80,
            rating: 0xFFDBBC7F)),
    _preset('atom_one', 'Atom One',
        light: const _Roles(
            primary: 0xFF4078F2, onPrimary: 0xFFFFFFFF, secondary: 0xFFA626A4,
            tertiary: 0xFF50A14F, surface: 0xFFFAFAFA, surfaceContainer: 0xFFF0F0F0,
            surfaceContainerHigh: 0xFFE5E5E6, onSurface: 0xFF383A42,
            onSurfaceVariant: 0xFF696C77, outline: 0xFFD4D4D6, error: 0xFFE45649,
            rating: 0xFFC18401),
        dark: const _Roles(
            primary: 0xFF61AFEF, onPrimary: 0xFF282C34, secondary: 0xFFC678DD,
            tertiary: 0xFF98C379, surface: 0xFF282C34, surfaceContainer: 0xFF2F343D,
            surfaceContainerHigh: 0xFF3B4048, onSurface: 0xFFABB2BF,
            onSurfaceVariant: 0xFF828997, outline: 0xFF4B5263, error: 0xFFE06C75,
            rating: 0xFFE5C07B)),
    _preset('ayu', 'Ayu',
        light: const _Roles(
            primary: 0xFFC96A00, onPrimary: 0xFFFFFFFF, secondary: 0xFF399EE6,
            tertiary: 0xFF4CBF99, surface: 0xFFFCFCFC, surfaceContainer: 0xFFF3F4F5,
            surfaceContainerHigh: 0xFFE7E8E9, onSurface: 0xFF5C6166,
            onSurfaceVariant: 0xFF8A9199, outline: 0xFFDCDDDE, error: 0xFFE65050,
            rating: 0xFFF2AE49),
        dark: const _Roles(
            primary: 0xFFE6B450, onPrimary: 0xFF0B0E14, secondary: 0xFF59C2FF,
            tertiary: 0xFF95E6CB, surface: 0xFF0B0E14, surfaceContainer: 0xFF131721,
            surfaceContainerHigh: 0xFF1E232D, onSurface: 0xFFBFBDB6,
            onSurfaceVariant: 0xFF808591, outline: 0xFF2D333F, error: 0xFFF07178,
            rating: 0xFFE6B450)),
    _preset('kanagawa', 'Kanagawa',
        light: const _Roles(
            primary: 0xFF4D699B, onPrimary: 0xFFFFFFFF, secondary: 0xFF766B90,
            tertiary: 0xFF6E915F, surface: 0xFFF2ECBC, surfaceContainer: 0xFFE5DDB0,
            surfaceContainerHigh: 0xFFDCD5A6, onSurface: 0xFF545464,
            onSurfaceVariant: 0xFF716E61, outline: 0xFFCAC1A0, error: 0xFFC84053,
            rating: 0xFFB98D3F),
        dark: const _Roles(
            primary: 0xFF7E9CD8, onPrimary: 0xFF1F1F28, secondary: 0xFF957FB8,
            tertiary: 0xFF7AA89F, surface: 0xFF1F1F28, surfaceContainer: 0xFF2A2A37,
            surfaceContainerHigh: 0xFF363646, onSurface: 0xFFDCD7BA,
            onSurfaceVariant: 0xFFA3A19A, outline: 0xFF54546D, error: 0xFFC34043,
            rating: 0xFFE6C384)),
    _preset('github', 'GitHub',
        light: const _Roles(
            primary: 0xFF0969DA, onPrimary: 0xFFFFFFFF, secondary: 0xFF8250DF,
            tertiary: 0xFF1A7F37, surface: 0xFFFFFFFF, surfaceContainer: 0xFFF6F8FA,
            surfaceContainerHigh: 0xFFEAEEF2, onSurface: 0xFF1F2328,
            onSurfaceVariant: 0xFF656D76, outline: 0xFFD0D7DE, error: 0xFFCF222E,
            rating: 0xFF9A6700),
        dark: const _Roles(
            primary: 0xFF58A6FF, onPrimary: 0xFF0D1117, secondary: 0xFFBC8CFF,
            tertiary: 0xFF3FB950, surface: 0xFF0D1117, surfaceContainer: 0xFF161B22,
            surfaceContainerHigh: 0xFF21262D, onSurface: 0xFFE6EDF3,
            onSurfaceVariant: 0xFF8B949E, outline: 0xFF30363D, error: 0xFFF85149,
            rating: 0xFFD29922)),
    _preset('sunset', 'Sunset',
        light: const _Roles(
            primary: 0xFFE4572E, onPrimary: 0xFFFFFFFF, secondary: 0xFFF3A712,
            tertiary: 0xFFA8577E, surface: 0xFFFFF8F3, surfaceContainer: 0xFFFDEDE2,
            surfaceContainerHigh: 0xFFFBE0CE, onSurface: 0xFF3A2A24,
            onSurfaceVariant: 0xFF7A5C4E, outline: 0xFFF1D3BE, error: 0xFFC0392B,
            rating: 0xFFE8A33D),
        dark: const _Roles(
            primary: 0xFFFF7A59, onPrimary: 0xFF2A1109, secondary: 0xFFFFC24B,
            tertiary: 0xFFE08AB0, surface: 0xFF1A1210, surfaceContainer: 0xFF241815,
            surfaceContainerHigh: 0xFF33211C, onSurface: 0xFFF6E7DE,
            onSurfaceVariant: 0xFFC2A798, outline: 0xFF43302A, error: 0xFFFF6B5E,
            rating: 0xFFFFC24B)),
    _preset('neon', 'Neon',
        light: const _Roles(
            primary: 0xFF0091AD, onPrimary: 0xFFFFFFFF, secondary: 0xFFD6157F,
            tertiary: 0xFF7A3CE0, surface: 0xFFF7F8FF, surfaceContainer: 0xFFEDEFFF,
            surfaceContainerHigh: 0xFFE0E4FF, onSurface: 0xFF14152B,
            onSurfaceVariant: 0xFF565A82, outline: 0xFFD2D6F5, error: 0xFFE11D48,
            rating: 0xFFB7891F),
        dark: const _Roles(
            primary: 0xFF00E5FF, onPrimary: 0xFF041014, secondary: 0xFFFF2E97,
            tertiary: 0xFFB26BFF, surface: 0xFF0A0A14, surfaceContainer: 0xFF14142A,
            surfaceContainerHigh: 0xFF1E1E3F, onSurface: 0xFFE8ECFF,
            onSurfaceVariant: 0xFF9AA0C7, outline: 0xFF2A2A55, error: 0xFFFF4D6D,
            rating: 0xFFFFE45E)),
  ];
}

ThemePreset _preset(
  String id,
  String name, {
  required _Roles light,
  required _Roles dark,
}) {
  return ThemePreset(
    id: id,
    name: name,
    light: _scheme(Brightness.light, light),
    dark: _scheme(Brightness.dark, dark),
    lightRating: Color(light.rating),
    darkRating: Color(dark.rating),
  );
}

/// Builds a complete [ColorScheme]: seeded by [r.primary] so all tonal
/// container/inverse roles are generated, with the palette's identity roles
/// pinned on top so the recognizable colors are exact.
///
/// Pinning hand-picked brand colors bypasses Material's contrast guarantees, so
/// a few legibility guards run over the pinned values before they're applied:
/// the on-primary button label, the secondary-text tone, and the card/surface
/// tonal steps are nudged only when they fall below a readable threshold. Colors
/// that are already fine pass through untouched, so the palettes stay faithful.
ColorScheme _scheme(Brightness brightness, _Roles r) {
  final isDark = brightness == Brightness.dark;

  // Button labels: keep the pinned on-color if it reads on the primary, else
  // pick black/white for the best contrast (bright/warm light primaries need
  // dark labels, which plain white would fail).
  final onPrimary = _ratio(Color(r.onPrimary), Color(r.primary)) >= 4.5
      ? r.onPrimary
      : _bestOn(r.primary);

  // Primary body text on the scaffold surface.
  final onSurface = _towardContrast(r.onSurface, r.surface, 4.5, isDark);

  // Secondary text / nav icons / input hints ride on onSurfaceVariant.
  final onSurfaceVariant = _towardContrast(
    r.onSurfaceVariant,
    r.surface,
    4.5,
    isDark,
  );

  // Keep the container tiers stepping the right direction from the scaffold
  // surface, and guarantee the card tier (highest) is a perceptible step away
  // so borderless, elevation-0 cards never dissolve into the background.
  final container = _towardContrast(r.surfaceContainer, r.surface, 1.06, isDark);
  final containerHigh = _towardContrast(
    r.surfaceContainerHigh,
    r.surface,
    1.14,
    isDark,
  );

  return ColorScheme.fromSeed(
    seedColor: Color(r.primary),
    brightness: brightness,
    primary: Color(r.primary),
    onPrimary: Color(onPrimary),
    secondary: Color(r.secondary),
    tertiary: Color(r.tertiary),
    error: Color(r.error),
    outline: Color(r.outline),
    onSurface: Color(onSurface),
    onSurfaceVariant: Color(onSurfaceVariant),
    surface: Color(r.surface),
    surfaceContainerLowest: Color(r.surface),
    surfaceContainerLow: Color(container),
    surfaceContainer: Color(container),
    surfaceContainerHigh: Color(containerHigh),
    surfaceContainerHighest: Color(containerHigh),
  );
}

/// WCAG relative-luminance contrast ratio between two colors (1.0 – 21.0).
double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Black or white — whichever reads better on [background].
int _bestOn(int background) {
  final bg = Color(background);
  return _ratio(const Color(0xFFFFFFFF), bg) >=
          _ratio(const Color(0xFF000000), bg)
      ? 0xFFFFFFFF
      : 0xFF000000;
}

/// Nudges [foreground] toward black (light themes) or white (dark themes) until
/// it clears [minRatio] against [background]. Returns it unchanged when it
/// already passes, so faithful colors are only touched when they'd be unreadable.
int _towardContrast(
  int foreground,
  int background,
  double minRatio,
  bool isDark,
) {
  final bg = Color(background);
  final start = Color(foreground);
  if (_ratio(start, bg) >= minRatio) return foreground;
  final target = isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  for (var t = 0.05; t <= 1.0; t += 0.05) {
    final candidate = Color.lerp(start, target, t)!;
    if (_ratio(candidate, bg) >= minRatio) return candidate.toARGB32();
  }
  return target.toARGB32();
}

/// Compact carrier for a single variant's pinned role colors (as ARGB ints).
@immutable
class _Roles {
  const _Roles({
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.tertiary,
    required this.surface,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.error,
    required this.rating,
  });

  final int primary;
  final int onPrimary;
  final int secondary;
  final int tertiary;
  final int surface;
  final int surfaceContainer;
  final int surfaceContainerHigh;
  final int onSurface;
  final int onSurfaceVariant;
  final int outline;
  final int error;
  final int rating;
}
