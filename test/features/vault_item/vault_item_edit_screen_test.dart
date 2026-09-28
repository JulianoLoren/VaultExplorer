import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_engine_events.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/features/vault_item/vault_item_edit_screen.dart';
import 'package:vaultexplorer/l10n/generated/app_localizations.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aeidolon.vaultexplorer/engine');
  late VaultEngineEvents engineEvents;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listDirectory') {
        return <String>[];
      }
      return true;
    });
    engineEvents = VaultEngineEvents();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget createWidget({VaultItem? existing}) {
    return ProviderScope(
      overrides: [
        vaultEngineEventsProvider.overrideWithValue(engineEvents),
      ],
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: VaultItemEditScreen(
          container: _testContainer(),
          type: VaultItemType.authenticator,
          existing: existing,
          currentDirPath: '',
        ),
      ),
    );
  }

  testWidgets('renders dropdown pickers for type, algorithm, digits, and period on new authenticator',
      (tester) async {
    await tester.pumpWidget(createWidget());
    await tester.pumpAndSettle();

    // Verify DropdownButtonFormField widgets exist
    final dropdownFinder = find.byType(DropdownButtonFormField<String>);
    expect(dropdownFinder, findsNWidgets(4));

    // Verify initial values in dropdowns
    expect(find.text('TOTP (Time-based)'), findsOneWidget);
    expect(find.text('SHA1'), findsOneWidget);
    expect(find.text('6 digits'), findsOneWidget);
    expect(find.text('30 seconds'), findsOneWidget);

    // hotp_counter should be hidden for TOTP
    expect(find.text('HOTP counter'), findsNothing);
  });

  testWidgets('switching type to HOTP reveals hotp_counter and hides period', (tester) async {
    await tester.pumpWidget(createWidget());
    await tester.pumpAndSettle();

    expect(find.text('HOTP counter'), findsNothing);
    expect(find.text('30 seconds'), findsOneWidget);

    // Tap the Type dropdown to open choices
    await tester.tap(find.text('TOTP (Time-based)'));
    await tester.pumpAndSettle();

    // Select HOTP option
    await tester.tap(find.text('HOTP (Counter-based)').last);
    await tester.pumpAndSettle();

    // Now HOTP counter should be visible and period should be hidden
    expect(find.text('HOTP counter'), findsOneWidget);
    expect(find.text('30 seconds'), findsNothing);
  });

  testWidgets('switching type to Steam Guard hides algorithm, digits, period, and counter', (tester) async {
    await tester.pumpWidget(createWidget());
    await tester.pumpAndSettle();

    expect(find.text('SHA1'), findsOneWidget);
    expect(find.text('6 digits'), findsOneWidget);

    // Tap Type dropdown
    await tester.tap(find.text('TOTP (Time-based)'));
    await tester.pumpAndSettle();

    // Select Steam Guard option
    await tester.tap(find.text('Steam Guard').last);
    await tester.pumpAndSettle();

    expect(find.text('SHA1'), findsNothing);
    expect(find.text('6 digits'), findsNothing);
    expect(find.text('30 seconds'), findsNothing);
    expect(find.text('HOTP counter'), findsNothing);
  });

  testWidgets('editing existing authenticator pre-selects saved algorithm, type, and digits', (tester) async {
    final existing = VaultItem(
      id: 'auth_1',
      type: VaultItemType.authenticator,
      title: 'GitHub',
      fields: {
        'totp_secret': 'JBSWY3DPEHPK3PXP',
        'totp_type': 'hotp',
        'totp_algorithm': 'SHA256',
        'totp_digits': '8',
        'hotp_counter': '42',
      },
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(createWidget(existing: existing));
    await tester.pumpAndSettle();

    expect(find.text('HOTP (Counter-based)'), findsOneWidget);
    expect(find.text('SHA256'), findsOneWidget);
    expect(find.text('8 digits'), findsOneWidget);
    expect(find.text('HOTP counter'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    // Period is hidden because type is HOTP
    expect(find.text('30 seconds'), findsNothing);
  });
}
