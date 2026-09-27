// The bottom sheet for choosing TextEditorScreen's background and syntax
// theme (Phase 3, item 1) plus relative line numbers (Phase 3, item 2).
// Every swatch is rendered using that option's own actual colors -- a
// syntax theme's chip is filled with its real root background and text
// color, not a separate icon standing in for it -- so a combination that
// clashes (e.g. a light background against a dark-designed syntax theme)
// is visible here before it's applied, rather than only discovered after.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_appearance_provider.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_theme.dart';

Future<void> showEditorAppearanceSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _EditorAppearanceSheet(),
  );
}

class _EditorAppearanceSheet extends ConsumerWidget {
  const _EditorAppearanceSheet();

  String _backgroundLabel(BuildContext context, EditorBackgroundOption option) => switch (option) {
    EditorBackgroundOption.matchSyntaxTheme => context.l10n.textEditorBackgroundMatchTheme,
    EditorBackgroundOption.amoledBlack => context.l10n.textEditorBackgroundAmoledBlack,
    EditorBackgroundOption.darkSlate => context.l10n.textEditorBackgroundDarkSlate,
    EditorBackgroundOption.classicLight => context.l10n.textEditorBackgroundClassicLight,
    EditorBackgroundOption.sepia => context.l10n.textEditorBackgroundSepia,
  };

  String _syntaxThemeLabel(BuildContext context, EditorSyntaxThemeOption option) => switch (option) {
    EditorSyntaxThemeOption.auto => context.l10n.textEditorSyntaxThemeAuto,
    EditorSyntaxThemeOption.oneDark => context.l10n.textEditorSyntaxThemeOneDark,
    EditorSyntaxThemeOption.dracula => context.l10n.textEditorSyntaxThemeDracula,
    EditorSyntaxThemeOption.githubLight => context.l10n.textEditorSyntaxThemeGithubLight,
    EditorSyntaxThemeOption.monokai => context.l10n.textEditorSyntaxThemeMonokai,
    EditorSyntaxThemeOption.nord => context.l10n.textEditorSyntaxThemeNord,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(textEditorAppearanceProvider);
    final notifier = ref.read(textEditorAppearanceProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    final appBrightness = Theme.of(context).brightness;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.textEditorThemeSheetTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.textEditorBackgroundSectionTitle,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in EditorBackgroundOption.values)
                  _BackgroundChip(
                    label: _backgroundLabel(context, option),
                    color: option.overrideColor ?? cs.surfaceContainerHighest,
                    textColor: option.overrideColor != null ? option.fallbackTextColor : cs.onSurface,
                    selected: prefs.background == option,
                    isAuto: option == EditorBackgroundOption.matchSyntaxTheme,
                    onTap: () => notifier.setBackground(option),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              context.l10n.textEditorSyntaxThemeSectionTitle,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in EditorSyntaxThemeOption.values)
                  _BackgroundChip(
                    label: _syntaxThemeLabel(context, option),
                    color: option.themeMap(appBrightness)['root']?.backgroundColor ?? cs.surfaceContainerHighest,
                    textColor: option.themeMap(appBrightness)['root']?.color ?? cs.onSurface,
                    selected: prefs.syntaxTheme == option,
                    isAuto: option == EditorSyntaxThemeOption.auto,
                    onTap: () => notifier.setSyntaxTheme(option),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.textEditorRelativeLineNumbersLabel),
              subtitle: Text(context.l10n.textEditorRelativeLineNumbersDescription),
              value: prefs.relativeLineNumbers,
              onChanged: notifier.setRelativeLineNumbers,
            ),
          ],
        ),
      ),
    );
  }
}

/// A selectable chip filled with [color]/[textColor] -- the swatch *is*
/// the preview, not a separate icon standing in for it. [isAuto] draws a
/// small "auto" glyph next to the label for the two "follow something
/// else" options (match theme / follow app brightness), which otherwise
/// wouldn't have one fixed color to show at all.
class _BackgroundChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final bool selected;
  final bool isAuto;
  final VoidCallback onTap;

  const _BackgroundChip({
    required this.label,
    required this.color,
    required this.textColor,
    required this.selected,
    required this.onTap,
    this.isAuto = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isAuto) ...[
                Icon(Icons.auto_awesome_rounded, size: 14, color: textColor),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_rounded, size: 16, color: textColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
