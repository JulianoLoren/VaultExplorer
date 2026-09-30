import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/data/models/file_manager_toolbar_config.dart';
import 'package:vaultexplorer/data/services/file_manager_toolbar_service.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/media_viewer_toolbar_settings_screen.dart';
import 'package:vaultexplorer/features/settings/file_manager_toolbar_settings_controller.dart';

class _FakeFileManagerToolbarService extends FileManagerToolbarService {
  FileManagerToolbarConfig _config = FileManagerToolbarConfig.defaults();

  @override
  Future<FileManagerToolbarConfig> load() async => _config;

  @override
  Future<void> save(FileManagerToolbarConfig config) async {
    _config = config;
  }
}

void main() {
  testWidgets('renders Swipe to Seek setting toggle and toggles state', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fakeService = _FakeFileManagerToolbarService();
    final container = ProviderContainer(
      overrides: [
        fileManagerToolbarServiceProvider.overrideWithValue(fakeService),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MediaViewerToolbarSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finder = find.widgetWithText(SwitchListTile, 'Swipe to Seek');
    expect(finder, findsOneWidget);

    final switchTile = tester.widget<SwitchListTile>(finder);
    expect(switchTile.value, isFalse);

    await tester.tap(finder);
    await tester.pumpAndSettle();

    final updatedTile = tester.widget<SwitchListTile>(finder);
    expect(updatedTile.value, isTrue);
    expect(
      container
          .read(fileManagerToolbarSettingsProvider(null))
          .config
          .mediaViewerToolbarConfig
          .swipeToSeekEnabled,
      isTrue,
    );
  });
}
