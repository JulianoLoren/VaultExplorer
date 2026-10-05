import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/browser/viewer/native_video_controller.dart';
import 'package:vaultexplorer/features/browser/viewer/caption_track.dart';
import 'package:vaultexplorer/features/browser/viewer/external_subtitles.dart';
import 'package:vaultexplorer/features/browser/viewer/video_playback_manager.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/media_player_widget.dart';
import 'package:vaultexplorer/l10n/generated/app_localizations.dart';

class _Controller extends NativeVideoController {
  _Controller({bool playing = true}) : super(volId: 1, filePath: 'Movie.mp4') {
    value = NativeVideoValue(
      isInitialized: true,
      hasRenderedFirstFrame: true,
      isPlaying: playing,
      position: const Duration(minutes: 5),
      duration: const Duration(minutes: 10),
      size: const Size(640, 360),
    );
  }
  double speed = 1;
  final seeks = <Duration>[];
  @override
  Future<void> setPlaybackSpeed(double next) async {
    speed = next;
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> seekTo(Duration target) async {
    seeks.add(target);
    value = value.copyWith(position: target);
  }

  @override
  Future<bool> startScrubPreview() async => false;
  @override
  Future<void> endScrubPreview() async {}
}

void main() {
  Future<
    (_Controller, ValueNotifier<VideoPlaybackProgress>, VideoPlaybackManager)
  >
  pumpPlayer(
    WidgetTester tester, {
    bool playing = true,
    bool swipeSeeking = false,
  }) async {
    final controller = _Controller(playing: playing);
    final manager = VideoPlaybackManager();
    final progress = ValueNotifier(const VideoPlaybackProgress());
    manager.currentFileNotifier.value = 'Movie.mp4';
    manager.activeControllerNotifier.value = controller;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MediaPlayerWidget(
              container: MountedContainer(
                uri: 'vault',
                displayName: 'Vault',
                volId: 1,
                rootFiles: [],
                mountedAt: DateTime(2026),
                totalSpace: 0,
                freeSpace: 0,
              ),
              fileName: 'Movie.mp4',
              contentUriString: '',
              showUI: true,
              onToggleUI: (_) {},
              onZoomChanged: (_) {},
              skipSeconds: 10,
              isAudio: false,
              subtitlesEnabled: true,
              playbackSpeed: 1,
              rotationQuarterTurns: 0,
              onSubtitlesAvailableChanged: (_) {},
              progressNotifier: progress,
              playbackManager: manager,
              swipeToSeekEnabled: swipeSeeking,
              edgeSwipeBrightnessEnabled: false,
              edgeSwipeVolumeEnabled: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      progress.dispose();
      await controller.dispose();
    });
    return (controller, progress, manager);
  }

  testWidgets(
    'hold then drag seeks both directions even when swipe seeking is off',
    (tester) async {
      final (controller, progress, _) = await pumpPlayer(tester);
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(MediaPlayerWidget)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.speed, 2);
      await touch.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(progress.value.isDragging, isTrue);
      expect(progress.value.position, greaterThan(const Duration(minutes: 5)));
      expect(controller.speed, 1);
      expect(controller.value.isPlaying, isFalse);
      await touch.moveBy(const Offset(-200, 0));
      await tester.pump();
      expect(progress.value.position, lessThan(const Duration(minutes: 5)));
      final target = progress.value.position;
      await touch.up();
      await tester.pump();
      expect(controller.seeks, [target]);
      expect(controller.value.isPlaying, isTrue);
      expect(progress.value.isDragging, isFalse);
    },
  );

  testWidgets(
    'hold without dragging restores playback speed and does not seek',
    (tester) async {
      final (controller, _, _) = await pumpPlayer(tester);
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(MediaPlayerWidget)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.speed, 2);
      await touch.up();
      await tester.pump();
      expect(controller.speed, 1);
      expect(controller.seeks, isEmpty);
    },
  );

  testWidgets('seeking a paused video leaves it paused', (tester) async {
    final (controller, progress, _) = await pumpPlayer(tester, playing: false);
    final touch = await tester.startGesture(
      tester.getCenter(find.byType(MediaPlayerWidget)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await touch.moveBy(const Offset(2000, 0));
    await tester.pump();
    expect(progress.value.position, const Duration(minutes: 10));
    await touch.up();
    await tester.pump();
    expect(controller.value.isPlaying, isFalse);
  });

  testWidgets(
    'cancelling a hold drag restores the original position without seeking',
    (tester) async {
      final (controller, progress, _) = await pumpPlayer(tester);
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(MediaPlayerWidget)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await touch.moveBy(const Offset(100, 0));
      await tester.pump();
      await touch.cancel();
      await tester.pump();
      expect(progress.value.position, const Duration(minutes: 5));
      expect(progress.value.isDragging, isFalse);
      expect(controller.seeks, isEmpty);
      expect(controller.value.isPlaying, isTrue);
    },
  );
  testWidgets(
    'selected external subtitles appear over the current video only',
    (tester) async {
      final (_, _, manager) = await pumpPlayer(tester);
      const subtitle = ExternalSubtitle(
        'Movie.srt',
        CaptionTrack([
          Caption(
            start: Duration(minutes: 4),
            end: Duration(minutes: 6),
            text: 'Xin chào',
          ),
        ]),
      );
      manager.selectExternalSubtitle('Another.mp4', subtitle);
      await tester.pump();
      expect(find.text('Xin chào'), findsNothing);
      manager.selectExternalSubtitle('Movie.mp4', subtitle);
      await tester.pump();
      expect(find.text('Xin chào'), findsOneWidget);
    },
  );
  testWidgets('hold seeking works alongside direct swipe seeking', (
    tester,
  ) async {
    final (controller, progress, _) = await pumpPlayer(
      tester,
      swipeSeeking: true,
    );
    final touch = await tester.startGesture(
      tester.getCenter(find.byType(MediaPlayerWidget)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await touch.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(progress.value.isDragging, isTrue);
    await touch.up();
    await tester.pump();
    expect(controller.seeks, hasLength(1));
    expect(controller.speed, 1);
  });

  testWidgets('a second finger cancels seeking until a fresh hold', (
    tester,
  ) async {
    final (controller, progress, _) = await pumpPlayer(tester);
    final center = tester.getCenter(find.byType(MediaPlayerWidget));
    final first = await tester.startGesture(center, pointer: 1);
    await tester.pump(const Duration(milliseconds: 600));
    await first.moveBy(const Offset(100, 0));
    await tester.pump();
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    expect(progress.value.isDragging, isFalse);
    await second.up();
    await first.moveBy(const Offset(100, 0));
    await first.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.seeks, isEmpty);
    expect(controller.speed, 1);
  });
}
