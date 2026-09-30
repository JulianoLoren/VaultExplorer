import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/browser/browser_dialogs.dart';

MountedContainer _testContainer() => MountedContainer(
      volId: 1,
      uri: 'file:///vault.hc',
      displayName: 'Vault',
      rootFiles: const [],
      mountedAt: DateTime(2026, 1, 1),
      totalSpace: 1000000,
      freeSpace: 500000,
      containerFormat: 'veracrypt',
    );

void main() {
  Widget buildTestApp({required void Function(BuildContext context) onLaunch}) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => onLaunch(context),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('New Text File preselects placeholder stem and keeps .txt extension',
      (WidgetTester tester) async {
    final container = _testContainer();

    await tester.pumpWidget(
      buildTestApp(
        onLaunch: (context) {
          BrowserDialogs.showCreateFile(
            context,
            container: container,
            currentDirPath: '',
            existingEntries: const [],
            onSuccess: () {},
          );
        },
      ),
    );

    // Tap to open the dialog
    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Dialog title
    expect(find.text('New Text File'), findsOneWidget);

    // Find TextField
    final textField = tester.widget<TextField>(find.byType(TextField));
    final controller = textField.controller!;

    // In English, filenameHint is 'filename.txt'
    expect(controller.text, 'filename.txt');
    // 'filename' (indices 0..8) should be selected, '.txt' should not be selected
    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, 8);

    // Create button should be enabled immediately
    final createButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Create'),
    );
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets(
      'New Text File makes filename unique and selects stem when filename.txt exists',
      (WidgetTester tester) async {
    final container = _testContainer();
    const existingFile = RawEntry(
      name: 'filename.txt',
      isDir: false,
      sizeBytes: 100,
      modifiedSecs: 1000,
    );

    await tester.pumpWidget(
      buildTestApp(
        onLaunch: (context) {
          BrowserDialogs.showCreateFile(
            context,
            container: container,
            currentDirPath: '',
            existingEntries: const [existingFile],
            onSuccess: () {},
          );
        },
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(find.byType(TextField));
    final controller = textField.controller!;

    // Should resolve collision to 'filename (1).txt'
    expect(controller.text, 'filename (1).txt');
    // 'filename (1)' (indices 0..12) should be selected
    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, 12);

    // Create button should be enabled
    final createButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Create'),
    );
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('Rename single file preselects stem excluding extension',
      (WidgetTester tester) async {
    final container = _testContainer();
    const existingFile = RawEntry(
      name: 'notes.txt',
      isDir: false,
      sizeBytes: 100,
      modifiedSecs: 1000,
    );

    await tester.pumpWidget(
      buildTestApp(
        onLaunch: (context) {
          BrowserDialogs.showRename(
            context,
            container: container,
            oldEntries: const [existingFile],
            existingEntries: const [existingFile],
            currentDirPath: '',
            onSuccess: () {},
          );
        },
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(find.byType(TextField));
    final controller = textField.controller!;

    expect(controller.text, 'notes.txt');
    // 'notes' (0..5) should be selected, '.txt' should not be selected
    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, 5);
  });
}
