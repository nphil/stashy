import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stash_app_flutter/core/data/preferences/shared_preferences_provider.dart';
import 'package:stash_app_flutter/core/presentation/theme/theme_preset_provider.dart';

void main() {
  group('AppThemePresetNotifier', () {
    test('build() returns the default (custom) when no preference is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(appThemePresetProvider), equals(defaultThemePresetId));
    });

    test('build() returns the saved preset id from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        appThemePresetPreferenceKey: 'nord',
      });
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(appThemePresetProvider), equals('nord'));
    });

    test('setPreset() updates state and persists to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(appThemePresetProvider), equals(defaultThemePresetId));
      expect(prefs.getString(appThemePresetPreferenceKey), isNull);

      await container.read(appThemePresetProvider.notifier).setPreset('dracula');

      expect(container.read(appThemePresetProvider), equals('dracula'));
      expect(prefs.getString(appThemePresetPreferenceKey), equals('dracula'));
    });

    test('setPreset() does not write when the id is unchanged', () async {
      // Seed empty so the default is 'custom'; setting it again must NOT write,
      // proving the early-return short-circuit fired (mirrors the color test).
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(appThemePresetProvider), equals(defaultThemePresetId));
      expect(prefs.getString(appThemePresetPreferenceKey), isNull);

      await container
          .read(appThemePresetProvider.notifier)
          .setPreset(defaultThemePresetId);

      expect(container.read(appThemePresetProvider), equals(defaultThemePresetId));
      // No write occurred on the unchanged path.
      expect(prefs.getString(appThemePresetPreferenceKey), isNull);
    });
  });
}
