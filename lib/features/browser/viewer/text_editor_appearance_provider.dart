// Manually-defined provider (no @riverpod/build_runner codegen), matching
// the pattern already used by e.g. ExternalStorageLocationsNotifier: a
// plain Notifier subclass plus a NotifierProvider constructed from it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultexplorer/data/services/text_editor_appearance_service.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_theme.dart';

class TextEditorAppearanceNotifier extends Notifier<TextEditorAppearancePrefs> {
  static const _service = TextEditorAppearanceService();

  @override
  TextEditorAppearancePrefs build() {
    _init();
    return const TextEditorAppearancePrefs();
  }

  Future<void> _init() async {
    state = await _service.load();
  }

  void setBackground(EditorBackgroundOption option) {
    state = state.copyWith(background: option);
    _service.save(state);
  }

  void setSyntaxTheme(EditorSyntaxThemeOption option) {
    state = state.copyWith(syntaxTheme: option);
    _service.save(state);
  }

  void setRelativeLineNumbers(bool enabled) {
    state = state.copyWith(relativeLineNumbers: enabled);
    _service.save(state);
  }
}

final textEditorAppearanceProvider =
    NotifierProvider<TextEditorAppearanceNotifier, TextEditorAppearancePrefs>(
      TextEditorAppearanceNotifier.new,
    );
