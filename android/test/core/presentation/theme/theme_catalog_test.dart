import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_app_flutter/core/presentation/theme/theme_catalog.dart';

/// WCAG relative-luminance contrast ratio (1.0 – 21.0).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('ThemeCatalog', () {
    test('exposes 16 palette families', () {
      expect(ThemeCatalog.presets.length, 16);
    });

    test('all preset ids are unique', () {
      final ids = ThemeCatalog.presets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('byId resolves a known preset and rejects unknown/special ids', () {
      expect(ThemeCatalog.byId('nord')?.name, 'Nord');
      expect(ThemeCatalog.byId(ThemeCatalog.customPresetId), isNull);
      expect(ThemeCatalog.byId(ThemeCatalog.dynamicPresetId), isNull);
      expect(ThemeCatalog.byId('not-a-real-theme'), isNull);
    });

    // The accessibility guards in _scheme must keep every catalog scheme
    // readable, so no future palette addition can silently ship an unreadable
    // button label, body/secondary text, or an invisible card.
    for (final preset in ThemeCatalog.presets) {
      final variants = <String, ColorScheme>{
        'light': preset.light,
        'dark': preset.dark,
      };
      variants.forEach((variant, s) {
        test('${preset.name} ($variant) meets contrast guards', () {
          // Button labels (FilledButton uses primary bg + onPrimary fg).
          expect(
            _contrast(s.onPrimary, s.primary),
            greaterThanOrEqualTo(4.4),
            reason: '${preset.id} $variant onPrimary vs primary',
          );
          // Primary body text on the scaffold surface.
          expect(
            _contrast(s.onSurface, s.surface),
            greaterThanOrEqualTo(4.4),
            reason: '${preset.id} $variant onSurface vs surface',
          );
          // Secondary text / nav icons / hints.
          expect(
            _contrast(s.onSurfaceVariant, s.surface),
            greaterThanOrEqualTo(4.4),
            reason: '${preset.id} $variant onSurfaceVariant vs surface',
          );
          // Borderless, elevation-0 cards must still separate from the surface.
          expect(
            _contrast(s.surfaceContainerHighest, s.surface),
            greaterThanOrEqualTo(1.12),
            reason: '${preset.id} $variant card vs surface',
          );
          // The scheme's declared brightness must match the variant.
          expect(
            s.brightness,
            variant == 'light' ? Brightness.light : Brightness.dark,
          );
        });
      });
    }
  });
}
