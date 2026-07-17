import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stash_app_flutter/core/utils/l10n_extensions.dart';
import 'package:stash_app_flutter/core/presentation/theme/app_theme.dart';
import 'package:stash_app_flutter/core/presentation/theme/theme_catalog.dart';
import 'package:stash_app_flutter/core/presentation/theme/theme_color_provider.dart';
import 'package:stash_app_flutter/core/presentation/theme/theme_preset_provider.dart';

/// A wrap of tappable mini-preview tiles for the theme catalog: Material You,
/// the 16 curated palette families (shown in the current brightness), and the
/// free-form Custom seed color. Selecting a tile persists it via
/// [appThemePresetProvider]; the whole app re-themes immediately.
class ThemeCatalogPicker extends ConsumerWidget {
  const ThemeCatalogPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(appThemePresetProvider);
    final seedColor = ref.watch(appThemeColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final notifier = ref.read(appThemePresetProvider.notifier);

    // Material You (dynamic_color) only yields real palettes on Android 12+;
    // showing the tile elsewhere would let it appear selected while the app
    // silently rendered the seed theme instead.
    final showMaterialYou = defaultTargetPlatform == TargetPlatform.android;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        if (showMaterialYou)
          _ThemeTile(
            label: context.l10n.settings_appearance_material_you,
            selected: selectedId == ThemeCatalog.dynamicPresetId,
            onTap: () => notifier.setPreset(ThemeCatalog.dynamicPresetId),
            preview: const _MaterialYouPreview(),
          ),
        for (final preset in ThemeCatalog.presets)
          _ThemeTile(
            label: preset.name,
            selected: selectedId == preset.id,
            onTap: () => notifier.setPreset(preset.id),
            preview: _SchemePreview(isDark ? preset.dark : preset.light),
          ),
        _ThemeTile(
          label: context.l10n.settings_appearance_theme_custom,
          selected: selectedId == ThemeCatalog.customPresetId,
          onTap: () => notifier.setPreset(ThemeCatalog.customPresetId),
          preview: _CustomPreview(seedColor),
        ),
      ],
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.preview,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = context.dimensions.fontSizeFactor;
    return SizedBox(
      width: 104 * scale,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 64 * scale,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: preview,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? scheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A mini app-surface preview: the scheme's surface with primary/secondary/
/// tertiary accent dots over a filled "button" bar.
class _SchemePreview extends StatelessWidget {
  const _SchemePreview(this.scheme);

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _Dot(scheme.primary),
                const SizedBox(width: 5),
                _Dot(scheme.secondary),
                const SizedBox(width: 5),
                _Dot(scheme.tertiary),
              ],
            ),
            const Spacer(),
            Container(
              height: 10,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _MaterialYouPreview extends StatelessWidget {
  const _MaterialYouPreview();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: SweepGradient(
          colors: [
            Color(0xFF4285F4),
            Color(0xFF9B72CB),
            Color(0xFFD96570),
            Color(0xFFF2A600),
            Color(0xFF34A853),
            Color(0xFF4285F4),
          ],
        ),
      ),
      child: Center(
        child: Icon(Icons.auto_awesome, color: Colors.white, size: 22),
      ),
    );
  }
}

class _CustomPreview extends StatelessWidget {
  const _CustomPreview(this.seedColor);

  final Color seedColor;

  @override
  Widget build(BuildContext context) {
    final onColor = seedColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return ColoredBox(
      color: seedColor,
      child: Center(
        child: Icon(Icons.colorize_outlined, color: onColor, size: 22),
      ),
    );
  }
}
