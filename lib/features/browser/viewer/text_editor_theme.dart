// Editor background and syntax-theme choices for TextEditorScreen -- see
// docs/text editor expansion plan, Phase 3, item 1 (EditorThemeConfig).
//
// These are two independent axes deliberately, matching how the plan lists
// them as separate sub-bullets ("Background colors" vs "Bundled syntax
// themes") rather than five or six pre-bundled combos: pick a background,
// pick a syntax theme, and EditorThemePickerSheet shows a live preview so
// a clashing combination (e.g. a light background against a syntax theme
// designed for a dark one) is visible before committing to it rather than
// silently allowed through.
//
// "Accent & Caret color" and "Gutter background color" from the same plan
// item aren't separately configurable here -- the gutter shares whatever
// the main background resolves to, and accent/caret color deliberately
// keeps following the app's own theme (ColorScheme.primary) rather than
// becoming a third, independent color picker.
import 'package:material_ui/material_ui.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_highlight/styles/base16/dracula.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/monokai.dart';
import 'package:re_highlight/styles/nord.dart';

enum EditorBackgroundOption {
  matchSyntaxTheme,
  amoledBlack,
  darkSlate,
  classicLight,
  sepia,
}

extension EditorBackgroundOptionX on EditorBackgroundOption {
  /// The override color for this option, or `null` for
  /// [EditorBackgroundOption.matchSyntaxTheme] -- meaning "use whatever
  /// background the chosen syntax theme's own `root` style specifies"
  /// (resolved in text_editor_language.dart, which is the one place that
  /// already reads a theme's `root` entry).
  Color? get overrideColor => switch (this) {
    EditorBackgroundOption.matchSyntaxTheme => null,
    EditorBackgroundOption.amoledBlack => const Color(0xFF000000),
    EditorBackgroundOption.darkSlate => const Color(0xFF1E1E2E),
    EditorBackgroundOption.classicLight => const Color(0xFFFFFFFF),
    EditorBackgroundOption.sepia => const Color(0xFFF4ECD8),
  };

  /// Reasonable default text color to pair with [overrideColor], used only
  /// as a fallback for files with no recognized syntax (so there's no
  /// codeTheme to read a text color from at all) -- when a codeTheme *is*
  /// active its own root text color is always used instead, since it's
  /// designed to have enough contrast against that theme's own tokens.
  Color get fallbackTextColor => switch (this) {
    EditorBackgroundOption.matchSyntaxTheme => const Color(0xFFABB2BF), // unused: overrideColor is null here
    EditorBackgroundOption.amoledBlack => const Color(0xFFE0E0E0),
    EditorBackgroundOption.darkSlate => const Color(0xFFCDD6F4),
    EditorBackgroundOption.classicLight => const Color(0xFF1A1A1A),
    EditorBackgroundOption.sepia => const Color(0xFF433422),
  };
}

enum EditorSyntaxThemeOption { auto, oneDark, dracula, githubLight, monokai, nord }

extension EditorSyntaxThemeOptionX on EditorSyntaxThemeOption {
  /// The re_highlight color map for this option. [appBrightness] only
  /// matters for [EditorSyntaxThemeOption.auto], which is the same
  /// dark/light-following-the-app behavior TextEditorScreen had before
  /// this picker existed.
  Map<String, TextStyle> themeMap(Brightness appBrightness) => switch (this) {
    EditorSyntaxThemeOption.auto =>
      appBrightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme,
    EditorSyntaxThemeOption.oneDark => atomOneDarkTheme,
    EditorSyntaxThemeOption.dracula => draculaTheme,
    EditorSyntaxThemeOption.githubLight => githubTheme,
    EditorSyntaxThemeOption.monokai => monokaiTheme,
    EditorSyntaxThemeOption.nord => nordTheme,
  };
}
