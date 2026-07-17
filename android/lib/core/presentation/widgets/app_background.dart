import 'package:flutter/material.dart';

/// Paints a subtle, theme-derived gradient behind the whole app when [enabled],
/// then makes descendant [Scaffold]s transparent so the gradient shows through
/// their empty background areas (app bars, cards and nav bars keep their own
/// opaque surfaces).
///
/// When disabled this is a no-op passthrough, so the solid
/// [ThemeData.scaffoldBackgroundColor] — including AMOLED true black — is used
/// unchanged. The gradient is derived from the active [ColorScheme], so it
/// re-tints automatically for every catalog theme, custom seed, or Material You
/// palette.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // A gentle diagonal wash: a touch of primary in the top-left, settling to
    // the flat surface, with a whisper of tertiary in the bottom-right. Blended
    // to fully opaque so it reads as a background, not a translucent overlay.
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          scheme.primary.withValues(alpha: 0.10),
          scheme.surface,
        ),
        scheme.surface,
        Color.alphaBlend(
          scheme.tertiary.withValues(alpha: 0.06),
          scheme.surfaceContainer,
        ),
      ],
      stops: const [0.0, 0.55, 1.0],
    );

    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: Theme(
        data: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: child,
      ),
    );
  }
}
