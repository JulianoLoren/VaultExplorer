// Persisted appearance choices for TextEditorScreen -- background,
// syntax theme (Phase 3, item 1), and relative line numbers (Phase 3,
// item 2). One shared set of choices across every file opened in the text
// editor, not per-file.
//
// Stored the same way AppSettingsService stores its own non-secret
// preferences: a plain JSON file in the app's documents directory. Not
// shared_preferences (this project doesn't depend on it, and everything
// else non-secret already goes through this same file-based pattern
// instead) and not AppSecureStorage (there's nothing secret about a color
// scheme or a line-number style).
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_theme.dart';

class TextEditorAppearancePrefs {
  final EditorBackgroundOption background;
  final EditorSyntaxThemeOption syntaxTheme;
  final bool relativeLineNumbers;

  const TextEditorAppearancePrefs({
    this.background = EditorBackgroundOption.matchSyntaxTheme,
    this.syntaxTheme = EditorSyntaxThemeOption.auto,
    this.relativeLineNumbers = false,
  });

  TextEditorAppearancePrefs copyWith({
    EditorBackgroundOption? background,
    EditorSyntaxThemeOption? syntaxTheme,
    bool? relativeLineNumbers,
  }) => TextEditorAppearancePrefs(
    background: background ?? this.background,
    syntaxTheme: syntaxTheme ?? this.syntaxTheme,
    relativeLineNumbers: relativeLineNumbers ?? this.relativeLineNumbers,
  );

  Map<String, dynamic> toJson() => {
    'background': background.name,
    'syntaxTheme': syntaxTheme.name,
    'relativeLineNumbers': relativeLineNumbers,
  };

  factory TextEditorAppearancePrefs.fromJson(Map<String, dynamic> json) {
    return TextEditorAppearancePrefs(
      background: EditorBackgroundOption.values.firstWhere(
        (o) => o.name == json['background'],
        orElse: () => EditorBackgroundOption.matchSyntaxTheme,
      ),
      syntaxTheme: EditorSyntaxThemeOption.values.firstWhere(
        (o) => o.name == json['syntaxTheme'],
        orElse: () => EditorSyntaxThemeOption.auto,
      ),
      relativeLineNumbers: json['relativeLineNumbers'] == true,
    );
  }
}

class TextEditorAppearanceService {
  const TextEditorAppearanceService();

  static Future<File> get _prefsFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/text_editor_appearance.json');
  }

  Future<TextEditorAppearancePrefs> load() async {
    try {
      final file = await _prefsFile;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return TextEditorAppearancePrefs.fromJson(raw);
      }
    } catch (_) {
      // Fall through to defaults -- same reasoning as AppSettingsService:
      // a corrupt or unreadable prefs file just means starting from
      // defaults, not a functional failure.
    }
    return const TextEditorAppearancePrefs();
  }

  Future<void> save(TextEditorAppearancePrefs prefs) async {
    try {
      final file = await _prefsFile;
      await file.writeAsString(jsonEncode(prefs.toJson()));
    } catch (_) {
      // The provider's in-memory state already reflects the change for
      // this session; a failed write only risks it not surviving a
      // restart, same as AppSettingsService.saveSettings.
    }
  }
}
