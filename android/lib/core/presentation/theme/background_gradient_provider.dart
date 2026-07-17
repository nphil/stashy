import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/preferences/shared_preferences_provider.dart';

/// Whether the app paints a subtle, theme-derived gradient behind every screen.
///
/// On by default (the themed background is part of the look); users who prefer a
/// flat surface — or pure black on OLED — can switch it off, restoring the solid
/// [ThemeData.scaffoldBackgroundColor].
class BackgroundGradientNotifier extends Notifier<bool> {
  static const _key = 'use_background_gradient';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(_key) ?? true;
  }

  Future<void> set(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_key, value);
  }
}

final backgroundGradientEnabledProvider =
    NotifierProvider<BackgroundGradientNotifier, bool>(
      BackgroundGradientNotifier.new,
    );
