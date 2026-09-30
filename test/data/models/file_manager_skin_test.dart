import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/data/models/file_manager_skin.dart';
import 'package:vaultexplorer/l10n/generated/app_localizations.dart';

void main() {
  group('FileManagerSkin defaults', () {
    test('classic equals a bare constructor', () {
      expect(FileManagerSkin.classic, const FileManagerSkin());
      expect(FileManagerSkin.classic.hashCode, const FileManagerSkin().hashCode);
    });

    test('classic keeps every option at its pre-skin value', () {
      const skin = FileManagerSkin.classic;
      for (final style in [skin.files, skin.folders]) {
        expect(style.iconFamily, SkinIconFamily.classic);
        expect(style.container, SkinContainerStyle.filled);
        expect(style.iconColorMode, SkinIconColorMode.auto);
        expect(style.customIconColor, isNull);
        expect(style.nameColor, isNull);
      }
      expect(skin.detailsColor, isNull);
      expect(skin.monospaceNames, isFalse);
    });

    test('files and folders are styled independently', () {
      final skin = FileManagerSkin.classic.copyWith(
        files: const SkinItemStyle(container: SkinContainerStyle.none),
      );
      expect(skin.files.container, SkinContainerStyle.none);
      expect(skin.folders.container, SkinContainerStyle.filled);
      expect(skin, isNot(FileManagerSkin.classic));
    });
  });

  group('FileManagerSkin JSON', () {
    const full = FileManagerSkin(
      files: SkinItemStyle(
        iconFamily: SkinIconFamily.outlined,
        container: SkinContainerStyle.outlined,
        iconColorMode: SkinIconColorMode.custom,
        customIconColor: Color(0xFF112233),
        nameColor: Color(0xFFAABBCC),
      ),
      folders: SkinItemStyle(
        iconFamily: SkinIconFamily.sharp,
        container: SkinContainerStyle.none,
        iconColorMode: SkinIconColorMode.neutral,
        nameColor: Color(0xFF00FF00),
      ),
      detailsColor: Color(0xFF445566),
      monospaceNames: true,
    );

    test('round-trips every field', () {
      expect(FileManagerSkin.fromJson(full.toJson()), full);
    });

    test('survives the jsonEncode/jsonDecode cycle storage performs', () {
      final restored = FileManagerSkin.fromJson(
        jsonDecode(jsonEncode(full.toJson())),
      );
      expect(restored, full);
    });

    test('keeps a non-opaque alpha channel', () {
      const translucent = FileManagerSkin(
        detailsColor: Color(0x80FF0000),
      );
      final restored = FileManagerSkin.fromJson(
        jsonDecode(jsonEncode(translucent.toJson())),
      );
      expect(restored.detailsColor, const Color(0x80FF0000));
    });

    test('a classic skin serializes to something that reads back as classic',
        () {
      final restored = FileManagerSkin.fromJson(
        jsonDecode(jsonEncode(FileManagerSkin.classic.toJson())),
      );
      expect(restored, FileManagerSkin.classic);
    });

    test('null, non-map and empty input all read as classic', () {
      expect(FileManagerSkin.fromJson(null), FileManagerSkin.classic);
      expect(FileManagerSkin.fromJson('nonsense'), FileManagerSkin.classic);
      expect(FileManagerSkin.fromJson(42), FileManagerSkin.classic);
      expect(FileManagerSkin.fromJson(<String, dynamic>{}),
          FileManagerSkin.classic);
    });

    test('unknown enum names fall back to the classic value per field', () {
      final skin = FileManagerSkin.fromJson({
        'files': {
          'iconFamily': 'holographic',
          'container': 'hexagon',
          'iconColorMode': 'rainbow',
        },
      });
      expect(skin.files.iconFamily, SkinIconFamily.classic);
      expect(skin.files.container, SkinContainerStyle.filled);
      expect(skin.files.iconColorMode, SkinIconColorMode.auto);
    });

    test('a bad field does not discard its valid neighbours', () {
      final skin = FileManagerSkin.fromJson({
        'files': {'iconFamily': 'holographic', 'container': 'none'},
        'monospaceNames': true,
      });
      expect(skin.files.iconFamily, SkinIconFamily.classic);
      expect(skin.files.container, SkinContainerStyle.none);
      expect(skin.monospaceNames, isTrue);
    });

    test('wrong-typed colors and flags are ignored, not thrown on', () {
      final skin = FileManagerSkin.fromJson({
        'files': {'customIconColor': 'red', 'nameColor': true},
        'folders': 'not a map',
        'detailsColor': <String>['x'],
        'monospaceNames': 'yes',
      });
      expect(skin.files.customIconColor, isNull);
      expect(skin.files.nameColor, isNull);
      expect(skin.folders, const SkinItemStyle());
      expect(skin.detailsColor, isNull);
      expect(skin.monospaceNames, isFalse);
    });

    test('numeric colors that decoded as doubles still read back', () {
      final skin = FileManagerSkin.fromJson({'detailsColor': 4278190335.0});
      expect(skin.detailsColor, const Color(0xFF0000FF));
    });
  });

  group('FileManagerSkin copyWith', () {
    test('unspecified fields are preserved', () {
      final changed = FileManagerSkin.classic
          .copyWith(monospaceNames: true)
          .copyWith(detailsColor: const Color(0xFF123456));
      expect(changed.monospaceNames, isTrue);
      expect(changed.detailsColor, const Color(0xFF123456));
    });

    test('clear flags remove a color that copyWith cannot null out', () {
      const style = SkinItemStyle(
        customIconColor: Color(0xFF111111),
        nameColor: Color(0xFF222222),
      );
      final cleared = style.copyWith(
        clearCustomIconColor: true,
        clearNameColor: true,
      );
      expect(cleared.customIconColor, isNull);
      expect(cleared.nameColor, isNull);

      final skin = const FileManagerSkin(detailsColor: Color(0xFF333333))
          .copyWith(clearDetailsColor: true);
      expect(skin.detailsColor, isNull);
    });
  });

  group('SkinPreset', () {
    test('classic preset is the classic skin', () {
      expect(SkinPreset.classic.skin, FileManagerSkin.classic);
    });

    test('every preset is distinct from every other', () {
      final skins = SkinPreset.values.map((p) => p.skin).toList();
      expect(skins.toSet().length, skins.length);
    });

    test('matchingPreset finds each preset', () {
      for (final preset in SkinPreset.values) {
        expect(preset.skin.matchingPreset, preset);
      }
    });

    test('matchingPreset is null once any single option is tweaked', () {
      for (final preset in SkinPreset.values) {
        final tweaked = preset.skin.copyWith(
          detailsColor: const Color(0xFFDEADBE),
        );
        expect(tweaked.matchingPreset, isNull, reason: preset.name);
      }
    });

    test('every preset survives storage and still matches itself', () {
      for (final preset in SkinPreset.values) {
        final restored = FileManagerSkin.fromJson(
          jsonDecode(jsonEncode(preset.skin.toJson())),
        );
        expect(restored.matchingPreset, preset, reason: preset.name);
      }
    });

    test('minimal outline is bare outlined icons with no boxes', () {
      final skin = SkinPreset.minimalOutline.skin;
      for (final style in [skin.files, skin.folders]) {
        expect(style.iconFamily, SkinIconFamily.outlined);
        expect(style.container, SkinContainerStyle.none);
      }
    });

    test('vivid uses a custom folder color with a color actually set', () {
      final folders = SkinPreset.vivid.skin.folders;
      expect(folders.iconColorMode, SkinIconColorMode.custom);
      expect(folders.customIconColor, isNotNull);
    });

    test('terminal turns on monospaced names', () {
      expect(SkinPreset.terminal.skin.monospaceNames, isTrue);
    });
  });

  group('skin enum JSON', () {
    test('every value of every enum round-trips by name', () {
      for (final v in SkinIconFamily.values) {
        expect(SkinIconFamily.fromJson(v.toJson()), v);
      }
      for (final v in SkinContainerStyle.values) {
        expect(SkinContainerStyle.fromJson(v.toJson()), v);
      }
      for (final v in SkinIconColorMode.values) {
        expect(SkinIconColorMode.fromJson(v.toJson()), v);
      }
    });
  });

  group('skin labels are translated in every supported locale', () {
    for (final locale in AppLocalizations.supportedLocales) {
      test(locale.languageCode, () {
        final l10n = lookupAppLocalizations(locale);
        final labels = <String>[
          for (final v in SkinIconFamily.values) v.getLocalizedLabel(l10n),
          for (final v in SkinContainerStyle.values) v.getLocalizedLabel(l10n),
          for (final v in SkinIconColorMode.values) v.getLocalizedLabel(l10n),
          for (final v in SkinPreset.values) v.getLocalizedLabel(l10n),
          l10n.fileSkinPresetCustom,
        ];
        for (final label in labels) {
          expect(label.trim(), isNotEmpty);
        }
      });
    }
  });
}
