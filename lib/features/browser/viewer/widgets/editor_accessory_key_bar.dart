// The bar pinned above the soft keyboard while editing a file in
// TextEditorScreen -- see docs/text editor expansion plan, Phase 2. Three
// horizontally-scrollable rows:
//   1. Symbols that are awkward to reach on a stock Android keyboard layout
//      (nested punctuation, brackets, quotes).
//   2. Undo/redo, left/right caret nav, select-word, and paste -- one-tap
//      versions of gestures that are fiddly with a fingertip on a small
//      screen.
//   3. The caret scrubber -- a full-width drag strip that moves the cursor
//      left/right one character per step of travel, so repositioning the
//      caret doesn't require a fingertip directly on top of it (which is
//      exactly what obscures the thing you're trying to aim at).
//
// Every button re-requests focus on the editor after acting: a Material
// `InkWell` can otherwise pull keyboard focus onto itself for a frame,
// which would dismiss the soft keyboard the bar is meant to sit above.
import 'dart:math' as math;
import 'package:flutter/rendering.dart' show AxisDirection;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show EditableText, ExcludeFocus, TapRegion;
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/data/services/text_editor_appearance_service.dart';
import 'package:vaultexplorer/data/services/text_editor_appearance_service.dart';

class EditorFocusNode extends FocusNode {
  bool keepFocusLocked = false;

  @override
  void unfocus({UnfocusDisposition disposition = UnfocusDisposition.scope}) {
    // Ignore requests to drop focus if the accessory bar is actively being touched
    if (keepFocusLocked) return;
    super.unfocus(disposition: disposition);
  }
}

class EditorAccessoryKeyBar extends StatelessWidget {
  final CodeLineEditingController controller;
  final FocusNode editorFocusNode;
  final List<String> symbols;

  const EditorAccessoryKeyBar({
    super.key,
    required this.controller,
    required this.editorFocusNode,
    this.symbols = TextEditorAppearancePrefs.defaultSymbols,
  });

  void _act(VoidCallback action) {
    action();
    if (!editorFocusNode.hasFocus) {
      editorFocusNode.requestFocus();
    }
  }

  void _insert(String symbol) => _act(() => controller.replaceSelection(symbol));

  void _selectWord() => _act(() {
    controller.moveCursorToWordBoundaryBackward();
    controller.extendSelectionToWordBoundaryForward();
  });

  void _copy() {
    _act(() {
      final selection = controller.selection;
      final baseIdx = selection.baseIndex;
      final baseOff = selection.baseOffset;
      final extIdx = selection.extentIndex;
      final extOff = selection.extentOffset;

      if (baseIdx == extIdx && baseOff == extOff) return;

      int startIdx, startOff, endIdx, endOff;
      if (baseIdx < extIdx || (baseIdx == extIdx && baseOff < extOff)) {
        startIdx = baseIdx;
        startOff = baseOff;
        endIdx = extIdx;
        endOff = extOff;
      } else {
        startIdx = extIdx;
        startOff = extOff;
        endIdx = baseIdx;
        endOff = baseOff;
      }

      final lines = controller.text.split('\n');
      final buffer = StringBuffer();
      
      for (int i = startIdx; i <= endIdx && i < lines.length; i++) {
        final line = lines[i];
        if (i == startIdx && i == endIdx) {
          buffer.write(line.substring(math.min(startOff, line.length), math.min(endOff, line.length)));
        } else if (i == startIdx) {
          buffer.write(line.substring(math.min(startOff, line.length)));
          buffer.write('\n');
        } else if (i == endIdx) {
          buffer.write(line.substring(0, math.min(endOff, line.length)));
        } else {
          buffer.write(line);
          buffer.write('\n');
        }
      }

      final textToCopy = buffer.toString();
      if (textToCopy.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: textToCopy));
      }
    });
  }

  void _cut() {
    _copy();
    _insert('');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    void setFocusLock(bool locked) {
      if (editorFocusNode is EditorFocusNode) {
        (editorFocusNode as EditorFocusNode).keepFocusLocked = locked;
      }
    }

    // We wrap the bar in two TapRegions. Standard TextFields use EditableText
    // as their TapRegion group, while many custom text editors use their own 
    // FocusNode. Wrapping in both ensures tapping the bar doesn't trigger the 
    // editor's "tap outside" detector. ExcludeFocus ensures no inner widget 
    // can steal focus through the gesture arena.
    // The Listener intercepts pointer events to lock the EditorFocusNode,
    // preventing re_editor from dropping focus before the button action fires.
    return Listener(
      onPointerDown: (_) => setFocusLock(true),
      onPointerUp: (_) => setFocusLock(false),
      onPointerCancel: (_) => setFocusLock(false),
      child: TapRegion(
        groupId: EditableText,
        child: TapRegion(
          groupId: editorFocusNode,
          child: ExcludeFocus(
            child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      itemCount: symbols.length,
                      separatorBuilder: (context, index) => const SizedBox(width: 4),
                      itemBuilder: (context, index) {
                        final symbol = symbols[index];
                        final isTab = symbol == 'Tab';
                        return _KeyButton(
                          label: symbol,
                          onTap: isTab ? () => _act(controller.applyIndent) : () => _insert(symbol),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, child) {
                        return ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          children: [
                            _IconKeyButton(
                              icon: Icons.undo_rounded,
                              tooltip: context.l10n.undoTooltip,
                              enabled: controller.canUndo,
                              onTap: () => _act(controller.undo),
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.redo_rounded,
                              tooltip: context.l10n.redoTooltip,
                              enabled: controller.canRedo,
                              onTap: () => _act(controller.redo),
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.keyboard_arrow_left_rounded,
                              tooltip: context.l10n.textEditorMoveCursorLeftTooltip,
                              onTap: () => _act(() => controller.moveCursor(AxisDirection.left)),
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.keyboard_arrow_right_rounded,
                              tooltip: context.l10n.textEditorMoveCursorRightTooltip,
                              onTap: () => _act(() => controller.moveCursor(AxisDirection.right)),
                            ),
                            const SizedBox(width: 4),
                          _IconKeyButton(
                              icon: Icons.highlight_alt_rounded,
                              tooltip: context.l10n.textEditorSelectWordTooltip,
                              onTap: _selectWord,
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.content_copy_rounded,
                              tooltip: context.l10n.copy,
                              onTap: _copy,
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.content_cut_rounded,
                              tooltip: context.l10n.cutTooltip,
                              onTap: _cut,
                            ),
                            const SizedBox(width: 4),
                            _IconKeyButton(
                              icon: Icons.content_paste_rounded,
                              tooltip: context.l10n.paste,
                              onTap: () => _act(controller.paste),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                 _CaretScrubber(controller: controller, editorFocusNode: editorFocusNode),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// A single symbol/text key -- sized to its label so `Tab` isn't cramped
/// next to single-character keys.
class _KeyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _KeyButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 34),
          height: 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontFamilyFallback: const ['monospace'],
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon key, optionally disabled (used for undo/redo when there's
/// nothing to undo/redo).
class _IconKeyButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  const _IconKeyButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(6),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 40,
          height: 34,
          alignment: Alignment.center,
          child: Tooltip(
            message: tooltip,
            child: Icon(
              icon,
              size: 20,
              color: enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-width horizontal drag strip: dragging right or left moves the
/// caret forward/backward one character per [_pixelsPerStep] of travel.
/// Lives in its own row (rather than layered on the text) specifically so
/// scrubbing doesn't put a fingertip over the caret it's positioning.
class _CaretScrubber extends StatefulWidget {
  final CodeLineEditingController controller;
  final FocusNode editorFocusNode;

  const _CaretScrubber({required this.controller, required this.editorFocusNode});

  @override
  State<_CaretScrubber> createState() => _CaretScrubberState();
}

class _CaretScrubberState extends State<_CaretScrubber> {
  static const double _pixelsPerStep = 10;
  // A single fast flick can report a large delta in one callback; cap how
  // many characters one update can move the caret so that stays a scrub,
  // not a teleport.
  static const int _maxStepsPerUpdate = 20;

  double _dragAccumulator = 0;
  bool _isDragging = false;

  void _onDragStart(DragStartDetails details) {
    _dragAccumulator = 0;
    setState(() => _isDragging = true);
    if (!widget.editorFocusNode.hasFocus) {
      widget.editorFocusNode.requestFocus();
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragAccumulator += details.delta.dx;
    var steps = 0;
    while (_dragAccumulator.abs() >= _pixelsPerStep && steps < _maxStepsPerUpdate) {
      if (_dragAccumulator > 0) {
        widget.controller.moveCursor(AxisDirection.right);
        _dragAccumulator -= _pixelsPerStep;
      } else {
        widget.controller.moveCursor(AxisDirection.left);
        _dragAccumulator += _pixelsPerStep;
      }
      steps++;
    }
  }

  void _onDragEnd(DragEndDetails details) => setState(() {
    _isDragging = false;
    _dragAccumulator = 0;
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      child: Semantics(
        label: context.l10n.textEditorCaretScrubberLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: () => setState(() {
            _isDragging = false;
            _dragAccumulator = 0;
          }),
          child: Container(
            height: 26,
            width: double.infinity,
            decoration: BoxDecoration(
              color: _isDragging ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chevron_left_rounded, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Container(
                  width: 28,
                  height: 3,
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 16, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}