import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/preferences/shared_preferences_provider.dart';
import 'theme_catalog.dart';

const appThemePresetPreferenceKey = 'app_theme_preset';

/// Default selection: the free-form seed color picker (backward compatible with
/// installs that only ever set [appThemeColorProvider]).
const defaultThemePresetId = ThemeCatalog.customPresetId;

/// Persists which theme is active: a catalog preset id (e.g. `nord`), the
/// special `custom` id (use the seed color), or `dynamic` (Material You).
///
/// The value is a plain string so the catalog can grow without a stored-enum
/// migration; unknown ids resolve to the custom/seed path at build time.
class AppThemePresetNotifier extends Notifier<String> {
  @override
  String build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return prefs.getString(appThemePresetPreferenceKey) ?? defaultThemePresetId;
  }

  Future<void> setPreset(String id) async {
    if (state == id) return;
    state = id;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(appThemePresetPreferenceKey, id);
  }
}

final appThemePresetProvider = NotifierProvider<AppThemePresetNotifier, String>(
  AppThemePresetNotifier.new,
);
