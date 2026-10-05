import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/services/session_lock_controller.dart';
import 'package:vaultexplorer/features/browser/viewer/external_subtitles.dart';
import 'package:vaultexplorer/features/browser/viewer/video_playback_manager.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/external_subtitle_selector.dart';
import 'package:vaultexplorer/l10n/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('subtitle-selector-test');
  final bytes = Uint8List.fromList(
    utf8.encode('1\n00:00:01,000 --> 00:00:03,000\nHello\n'),
  );
  late VideoPlaybackManager manager;
  late SessionLockController lock;
  late int selected;
  Map<String, Object>? picked;
  bool invalid = false;

  setUp(() {
    manager = VideoPlaybackManager();
    lock = SessionLockController();
    selected = 0;
    invalid = false;
    picked = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'listDirectory':
              return [
                'F|40|0|Other.srt',
                'F|40|0|Movie.vi.srt',
                'F|40|0|Movie.srt',
              ];
            case 'getFileSize':
              return bytes.length;
            case 'readFileChunk':
              return invalid ? Uint8List.fromList([1, 2]) : bytes;
            case 'pickSubtitleFile':
              expect(lock.isLockSuppressed, isTrue);
              return picked;
            default:
              throw StateError(call.method);
          }
        });
  });
  tearDown(() {
    manager.dispose();
    lock.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpSelector(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultFileIoApiProvider.overrideWithValue(
            const VaultFileIoApi(channel),
          ),
          sessionLockControllerProvider.overrideWithValue(lock),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ExternalSubtitleSelector(
              container: MountedContainer(
                uri: 'vault',
                displayName: 'Vault',
                volId: 1,
                rootFiles: [],
                mountedAt: DateTime(2026),
                totalSpace: 0,
                freeSpace: 0,
              ),
              video: 'Movie.mp4',
              playbackManager: manager,
              onSelected: () => selected++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows sorted siblings and selects a caption track', (
    tester,
  ) async {
    await pumpSelector(tester);
    expect(
      tester.getTopLeft(find.text('Movie.srt')).dy,
      lessThan(tester.getTopLeft(find.text('Movie.vi.srt')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Movie.vi.srt')).dy,
      lessThan(tester.getTopLeft(find.text('Other.srt')).dy),
    );
    await tester.tap(find.text('Movie.vi.srt'));
    await tester.pumpAndSettle();
    expect(
      manager.externalSubtitles.value['Movie.mp4']?.sourcePath,
      'Movie.vi.srt',
    );
    expect(selected, 1);
  });

  testWidgets('loads a device file and restores auto-lock after the picker', (
    tester,
  ) async {
    picked = {
      'name': 'Device.vtt',
      'bytes': Uint8List.fromList(
        utf8.encode('WEBVTT\n\n00:01.000 --> 00:03.000\nDevice captions\n'),
      ),
    };
    await pumpSelector(tester);
    await tester.tap(find.text('Choose subtitle file…'));
    await tester.pumpAndSettle();
    expect(manager.externalSubtitles.value['Movie.mp4']?.name, 'Device.vtt');
    expect(lock.isLockSuppressed, isFalse);
    expect(selected, 1);
  });

  testWidgets('cancelled and invalid selections keep the existing captions', (
    tester,
  ) async {
    final original = ExternalSubtitle.parse('Existing.srt', bytes);
    manager.selectExternalSubtitle('Movie.mp4', original);
    await pumpSelector(tester);
    await tester.tap(find.text('Choose subtitle file…'));
    await tester.pumpAndSettle();
    expect(lock.isLockSuppressed, isFalse);
    expect(manager.externalSubtitles.value['Movie.mp4'], same(original));
    invalid = true;
    await tester.tap(find.text('Other.srt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load subtitles.'), findsOneWidget);
    expect(manager.externalSubtitles.value['Movie.mp4'], same(original));
    expect(selected, 0);
  });
}
