import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/theme/file_manager_skin_scope.dart';
import 'package:vaultexplorer/core/utils/file_type_utils.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/data/models/file_manager_skin.dart';
import 'package:vaultexplorer/features/browser/widgets/directory_tile.dart';
import 'package:vaultexplorer/features/browser/widgets/file_tile.dart';
import 'package:vaultexplorer/features/browser/widgets/grid_card_shell.dart';
import 'package:vaultexplorer/l10n/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child, {FileManagerSkin? skin}) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 240,
              child: skin == null
                  ? child
                  : FileManagerSkinScope(skin: skin, child: child),
            ),
          ),
        ),
      ),
    );
  }

  const folderEntry = RawEntry(
    name: 'Documents',
    isDir: true,
    sizeBytes: 0,
    modifiedSecs: 1690000000,
  );

  const fileEntry = RawEntry(
    name: 'page.html',
    isDir: false,
    sizeBytes: 2048,
    modifiedSecs: 1690000000,
  );

  Widget directoryTile() => DirectoryTile(
        entry: folderEntry,
        isSelectionMode: false,
        isSelected: false,
        showItemActionsMenu: false,
        onTap: () {},
        onLongPress: () {},
      );

  Widget fileTile() => FileTile(
        entry: fileEntry,
        isSelectionMode: false,
        isSelected: false,
        showItemActionsMenu: false,
        onTap: () {},
        onLongPress: () {},
      );

  /// The box drawn behind a row's leading icon: the `Container` whose direct
  /// child is [icon].
  Container leadingBox(WidgetTester tester, IconData icon) {
    return tester.widget<Container>(
      find.byWidgetPredicate(
        (w) => w is Container && w.child is Icon && (w.child as Icon).icon == icon,
      ),
    );
  }

  BoxDecoration decorationOf(Container c) => c.decoration! as BoxDecoration;

  Icon iconWidget(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon));

  ColorScheme schemeOf(WidgetTester tester, Type type) =>
      Theme.of(tester.element(find.byType(type))).colorScheme;

  group('FileManagerSkinScope', () {
    testWidgets('without a scope, tiles see the classic skin', (tester) async {
      FileManagerSkin? seen;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              seen = FileManagerSkinScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, FileManagerSkin.classic);
    });

    testWidgets('provides the skin it was given', (tester) async {
      FileManagerSkin? seen;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              seen = FileManagerSkinScope.of(context);
              return const SizedBox();
            },
          ),
          skin: SkinPreset.terminal.skin,
        ),
      );
      expect(seen, SkinPreset.terminal.skin);
    });

    testWidgets('dependents rebuild when the skin changes, not when it is '
        'merely re-created equal', (tester) async {
      var builds = 0;
      // One stable widget instance reused across pumps. A freshly created
      // child would be rebuilt by its parent no matter what the scope says,
      // which would hide whether updateShouldNotify is doing its job.
      final probe = Builder(
        builder: (context) {
          FileManagerSkinScope.of(context);
          builds++;
          return const SizedBox();
        },
      );
      Widget build(FileManagerSkin skin) => host(probe, skin: skin);

      await tester.pumpWidget(build(SkinPreset.minimalOutline.skin));
      final initial = builds;
      expect(initial, greaterThan(0));

      // A new-but-equal skin instance: dependents are not rebuilt.
      await tester.pumpWidget(build(SkinPreset.minimalOutline.skin));
      expect(builds, initial);

      // A different skin: dependents are rebuilt.
      await tester.pumpWidget(build(SkinPreset.vivid.skin));
      expect(builds, greaterThan(initial));
    });
  });

  group('DirectoryTile', () {
    testWidgets('no scope and an explicit classic scope look identical', (
      tester,
    ) async {
      await tester.pumpWidget(host(directoryTile()));
      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      final bare = decorationOf(leadingBox(tester, Icons.folder_rounded));
      final bareColor = iconWidget(tester, Icons.folder_rounded).color;
      final bareName =
          tester.widget<Text>(find.text('Documents')).style;

      await tester.pumpWidget(
        host(directoryTile(), skin: FileManagerSkin.classic),
      );
      final scoped = decorationOf(leadingBox(tester, Icons.folder_rounded));

      expect(scoped.color, bare.color);
      expect(scoped.border, bare.border);
      expect(iconWidget(tester, Icons.folder_rounded).color, bareColor);
      expect(tester.widget<Text>(find.text('Documents')).style, bareName);
    });

    testWidgets('classic draws a tinted box and the secondary color', (
      tester,
    ) async {
      await tester.pumpWidget(host(directoryTile()));
      final box = decorationOf(leadingBox(tester, Icons.folder_rounded));
      expect(box.color, isNotNull);
      expect(box.color, isNot(Colors.transparent));
      expect(box.border, isNull);
      expect(
        iconWidget(tester, Icons.folder_rounded).color,
        schemeOf(tester, DirectoryTile).secondary,
      );
    });

    testWidgets('minimal outline: outlined folder, no box, neutral color', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(directoryTile(), skin: SkinPreset.minimalOutline.skin),
      );
      expect(find.byIcon(Icons.folder_rounded), findsNothing);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

      final box = decorationOf(leadingBox(tester, Icons.folder_outlined));
      expect(box.color, Colors.transparent);
      expect(box.border, isNull);
      expect(
        iconWidget(tester, Icons.folder_outlined).color,
        schemeOf(tester, DirectoryTile).onSurfaceVariant,
      );
    });

    testWidgets('frames: transparent box with an outline border', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(directoryTile(), skin: SkinPreset.frames.skin),
      );
      final box = decorationOf(leadingBox(tester, Icons.folder_outlined));
      expect(box.color, Colors.transparent);
      expect(box.border, isNotNull);
    });

    testWidgets('vivid: filled folder in the custom golden color', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(directoryTile(), skin: SkinPreset.vivid.skin),
      );
      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(
        iconWidget(tester, Icons.folder).color,
        const Color(0xFFFFB300),
      );
    });

    testWidgets('folder name color and monospace font are applied', (
      tester,
    ) async {
      const skin = FileManagerSkin(
        folders: SkinItemStyle(nameColor: Color(0xFFD81B60)),
        monospaceNames: true,
      );
      await tester.pumpWidget(host(directoryTile(), skin: skin));
      final style = tester.widget<Text>(find.text('Documents')).style;
      expect(style?.color, const Color(0xFFD81B60));
      expect(style?.fontFamily, kSkinMonospaceFontFamily);
    });

    testWidgets('a files-only skin change leaves folders alone', (
      tester,
    ) async {
      await tester.pumpWidget(host(directoryTile()));
      final before = decorationOf(leadingBox(tester, Icons.folder_rounded));

      const skin = FileManagerSkin(
        files: SkinItemStyle(
          iconFamily: SkinIconFamily.sharp,
          container: SkinContainerStyle.none,
          nameColor: Color(0xFF00FF00),
        ),
      );
      await tester.pumpWidget(host(directoryTile(), skin: skin));

      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      final after = decorationOf(leadingBox(tester, Icons.folder_rounded));
      expect(after.color, before.color);
      expect(after.border, before.border);
      expect(
        tester.widget<Text>(find.text('Documents')).style?.color,
        isNot(const Color(0xFF00FF00)),
      );
    });
  });

  group('FileTile', () {
    testWidgets('classic keeps the type icon and type color', (tester) async {
      await tester.pumpWidget(host(fileTile()));
      expect(find.byIcon(iconForFile('page.html')), findsOneWidget);
      expect(
        iconWidget(tester, iconForFile('page.html')).color,
        colorForFile('page.html'),
      );
      final box = decorationOf(leadingBox(tester, iconForFile('page.html')));
      expect(box.color, isNot(Colors.transparent));
      expect(box.border, isNull);
    });

    testWidgets('outlined family swaps the glyph for the same kind of file', (
      tester,
    ) async {
      const skin = FileManagerSkin(
        files: SkinItemStyle(iconFamily: SkinIconFamily.outlined),
      );
      await tester.pumpWidget(host(fileTile(), skin: skin));
      // Classic shows `language_rounded` for HTML; outlined swaps only the
      // style of that same web glyph.
      expect(find.byIcon(Icons.language_rounded), findsNothing);
      expect(find.byIcon(Icons.language_outlined), findsOneWidget);
    });

    testWidgets('minimal outline: no box and a neutral icon color', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(fileTile(), skin: SkinPreset.minimalOutline.skin),
      );
      final box = decorationOf(leadingBox(tester, Icons.language_outlined));
      expect(box.color, Colors.transparent);
      expect(box.border, isNull);
      expect(
        iconWidget(tester, Icons.language_outlined).color,
        schemeOf(tester, FileTile).onSurfaceVariant,
      );
    });

    testWidgets('file name color is applied', (tester) async {
      const skin = FileManagerSkin(
        files: SkinItemStyle(nameColor: Color(0xFF3949AB)),
      );
      await tester.pumpWidget(host(fileTile(), skin: skin));
      expect(
        tester.widget<Text>(find.text('page.html')).style?.color,
        const Color(0xFF3949AB),
      );
    });

    testWidgets('details color is applied to the date and size columns', (
      tester,
    ) async {
      const skin = FileManagerSkin(detailsColor: Color(0xFFFB8C00));
      await tester.pumpWidget(host(fileTile(), skin: skin));

      // Compared ignoring alpha: the two-line layout draws its caption in
      // the same color at slightly reduced opacity.
      final orange = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.style?.color?.withValues(alpha: 1) == const Color(0xFFFB8C00),
      );
      expect(orange, findsWidgets);
    });
  });

  group('GridCardShell', () {
    Widget card({
      bool isFolder = false,
      bool isSelected = false,
      FileManagerSkin? skin,
    }) {
      return host(
        GridCardShell(
          isFolder: isFolder,
          preview: const ColoredBox(color: Colors.blue),
          label: 'Item',
          isSelected: isSelected,
          isSelectionMode: isSelected,
          onTap: () {},
          onLongPress: () {},
        ),
        skin: skin,
      );
    }

    Card cardOf(WidgetTester tester) => tester.widget<Card>(find.byType(Card));
    BorderSide sideOf(Card c) => (c.shape! as RoundedRectangleBorder).side;

    testWidgets('classic is a tinted card with no border', (tester) async {
      await tester.pumpWidget(card());
      final c = cardOf(tester);
      expect(c.color, isNot(Colors.transparent));
      expect(sideOf(c), BorderSide.none);
    });

    testWidgets('none: transparent card with no border', (tester) async {
      await tester.pumpWidget(card(skin: SkinPreset.minimalOutline.skin));
      final c = cardOf(tester);
      expect(c.color, Colors.transparent);
      expect(sideOf(c), BorderSide.none);
    });

    testWidgets('outlined: transparent card with a thin outline', (
      tester,
    ) async {
      await tester.pumpWidget(card(skin: SkinPreset.frames.skin));
      final c = cardOf(tester);
      expect(c.color, Colors.transparent);
      expect(sideOf(c).width, 1.2);
      expect(sideOf(c).color, schemeOf(tester, GridCardShell).outlineVariant);
    });

    testWidgets('selection stays visible whatever the skin', (tester) async {
      await tester.pumpWidget(
        card(isSelected: true, skin: SkinPreset.minimalOutline.skin),
      );
      final c = cardOf(tester);
      expect(c.color, isNot(Colors.transparent));
      expect(sideOf(c).width, 2.0);
      expect(sideOf(c).color, schemeOf(tester, GridCardShell).primary);
    });

    testWidgets('isFolder picks the folder style, otherwise the file style', (
      tester,
    ) async {
      const skin = FileManagerSkin(
        folders: SkinItemStyle(container: SkinContainerStyle.none),
      );

      await tester.pumpWidget(card(isFolder: true, skin: skin));
      expect(cardOf(tester).color, Colors.transparent);

      await tester.pumpWidget(card(isFolder: false, skin: skin));
      expect(cardOf(tester).color, isNot(Colors.transparent));
    });

    testWidgets('label takes the per-kind name color', (tester) async {
      const skin = FileManagerSkin(
        folders: SkinItemStyle(nameColor: Color(0xFF8E24AA)),
        files: SkinItemStyle(nameColor: Color(0xFF00897B)),
      );

      await tester.pumpWidget(card(isFolder: true, skin: skin));
      expect(
        tester.widget<Text>(find.text('Item')).style?.color,
        const Color(0xFF8E24AA),
      );

      await tester.pumpWidget(card(isFolder: false, skin: skin));
      expect(
        tester.widget<Text>(find.text('Item')).style?.color,
        const Color(0xFF00897B),
      );
    });
  });
}
