// The find/replace bar for TextEditorScreen -- see docs/text editor
// expansion plan, Phase 4, item 3. Docks itself above the code (re_editor
// reads `preferredSize` to push the text down, then stacks this on top --
// see `CodeEditor.findBuilder`), rather than the bottom sheet the original
// plan sketched: that's what the widget's own docking hook is built for,
// and a top-docked find bar next to a top AppBar is also the more familiar
// placement (VS Code, Sublime, etc. all dock find at the top).
//
// The actual search/replace engine -- regex compilation, match scanning,
// current-match tracking -- is entirely `CodeFindController`'s; this widget
// only renders its state and calls its methods. In particular
// `findInputController`/`replaceInputController` are plain
// TextEditingControllers CodeFindController already listens to itself, so
// binding a bare TextField to each is enough to make typing re-run the
// search -- no onChanged wiring needed here.
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';

class EditorFindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final bool readOnly;

  const EditorFindPanel({super.key, required this.controller, required this.readOnly});

  bool get _showReplaceRow => !readOnly && (controller.value?.replaceMode ?? false);

  @override
  Size get preferredSize => Size.fromHeight(_showReplaceRow ? 92 : 48);

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    // findBuilder only renders this widget once `controller.value` is
    // non-null (see TextEditorScreen), but guard anyway rather than assume
    // the caller always does that correctly.
    if (value == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final result = value.result;
    final matchCount = result?.matches.length ?? 0;
    final currentIndex = result?.index ?? -1;
    final hasQuery = value.option.pattern.isNotEmpty;

    return Material(
      color: cs.surfaceContainerHigh,
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    if (!readOnly)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          value.replaceMode ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                        ),
                        tooltip: context.l10n.textEditorToggleReplaceTooltip,
                        onPressed: controller.toggleMode,
                      ),
                    Expanded(
                      child: TextField(
                        controller: controller.findInputController,
                        focusNode: controller.findInputFocusNode,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: context.l10n.textEditorFindHint,
                        ),
                        onSubmitted: (_) {
                          if (matchCount > 0) controller.nextMatch();
                        },
                      ),
                    ),
                    if (hasQuery) ...[
                      Text(
                        matchCount == 0
                            ? context.l10n.textEditorNoMatches
                            : '${currentIndex + 1}/$matchCount',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(width: 4),
                    ],
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      tooltip: context.l10n.textEditorPreviousMatchTooltip,
                      onPressed: matchCount > 0 ? controller.previousMatch : null,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      tooltip: context.l10n.textEditorNextMatchTooltip,
                      onPressed: matchCount > 0 ? controller.nextMatch : null,
                    ),
                    _ToggleChip(
                      label: 'Aa',
                      active: value.option.caseSensitive,
                      tooltip: context.l10n.textEditorCaseSensitiveTooltip,
                      onTap: controller.toggleCaseSensitive,
                    ),
                    const SizedBox(width: 4),
                    _ToggleChip(
                      label: '.*',
                      active: value.option.regex,
                      tooltip: context.l10n.textEditorRegexTooltip,
                      onTap: controller.toggleRegex,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded),
                      tooltip: context.l10n.textEditorCloseFindTooltip,
                      onPressed: controller.close,
                    ),
                  ],
                ),
              ),
              if (_showReplaceRow)
                SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      const SizedBox(width: 40),
                      Expanded(
                        child: TextField(
                          controller: controller.replaceInputController,
                          focusNode: controller.replaceInputFocusNode,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: context.l10n.textEditorReplaceHint,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: matchCount > 0 ? controller.replaceMatch : null,
                        child: Text(context.l10n.textEditorReplaceButton),
                      ),
                      TextButton(
                        onPressed: matchCount > 0 ? controller.replaceAllMatches : null,
                        child: Text(context.l10n.textEditorReplaceAllButton),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small two-character toggle used for the case-sensitivity ("Aa") and
/// regex (".*") switches -- the same shorthand most code editors use for
/// these two, so it reads at a glance rather than needing a label.
class _ToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  const _ToggleChip({
    required this.label,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
