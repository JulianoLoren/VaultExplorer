import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_chrome.dart';

void main() {
  final darkApp = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );
  final lightApp = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.light,
  );

  group('EditorChrome.resolve', () {
    test('surfaces and text follow the editor colors, not the app scheme', () {
      const bg = Color(0xFFF4ECD8); // Sepia
      const fg = Color(0xFF433422);
      final chrome = EditorChrome.resolve(
        background: bg,
        foreground: fg,
        appScheme: darkApp,
      );

      expect(chrome.colorScheme.surface, bg);
      expect(chrome.colorScheme.onSurface, fg);
      expect(chrome.colorScheme.surfaceContainerLow, bg);
      expect(chrome.colorScheme.brightness, Brightness.light);
      expect(chrome.theme.scaffoldBackgroundColor, bg);
      expect(chrome.theme.brightness, Brightness.light);
    });

    test('system navigation icons contrast with the editor background', () {
      final onBlack = EditorChrome.resolve(
        background: const Color(0xFF000000),
        foreground: const Color(0xFFE0E0E0),
        appScheme: lightApp,
      );
      expect(onBlack.overlayStyle.systemNavigationBarIconBrightness, Brightness.light);
      expect(onBlack.overlayStyle.statusBarIconBrightness, Brightness.light);
      expect(onBlack.overlayStyle.systemNavigationBarColor, onBlack.colorScheme.surfaceContainerLow);

      final onWhite = EditorChrome.resolve(
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF1A1A1A),
        appScheme: darkApp,
      );
      expect(onWhite.overlayStyle.systemNavigationBarIconBrightness, Brightness.dark);
      expect(onWhite.overlayStyle.statusBarIconBrightness, Brightness.dark);
    });

    test('keeps the app palette when brightness agrees, re-derives it when not', () {
      final same = EditorChrome.resolve(
        background: const Color(0xFF1E1E2E),
        foreground: const Color(0xFFCDD6F4),
        appScheme: darkApp,
      );
      expect(same.colorScheme.primary, darkApp.primary);

      final flipped = EditorChrome.resolve(
        background: const Color(0xFF1E1E2E),
        foreground: const Color(0xFFCDD6F4),
        appScheme: lightApp,
      );
      expect(flipped.colorScheme.primary, isNot(lightApp.primary));
      expect(flipped.colorScheme.brightness, Brightness.dark);
    });
  });

  group('EditorChrome.matches', () {
    test('is true only for identical inputs', () {
      const bg = Color(0xFF000000);
      const fg = Color(0xFFE0E0E0);
      final chrome = EditorChrome.resolve(
        background: bg,
        foreground: fg,
        appScheme: darkApp,
      );

      expect(chrome.matches(bg, fg, darkApp), isTrue);
      expect(chrome.matches(const Color(0xFF1E1E2E), fg, darkApp), isFalse);
      expect(chrome.matches(bg, const Color(0xFFFFFFFF), darkApp), isFalse);
      expect(chrome.matches(bg, fg, lightApp), isFalse);
    });
  });
}
