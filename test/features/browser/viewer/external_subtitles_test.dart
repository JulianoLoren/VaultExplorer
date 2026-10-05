import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/browser/viewer/external_subtitles.dart';
import 'package:vaultexplorer/features/browser/viewer/video_playback_manager.dart';

const _srt = '1\n00:00:01,000 --> 00:00:03,000\nXin chào\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('subtitle-test');
  final api = VaultFileIoApi(channel);
  final container = MountedContainer(
    uri: 'vault',
    displayName: 'Vault',
    volId: 1,
    rootFiles: [],
    mountedAt: DateTime(2026),
    totalSpace: 0,
    freeSpace: 0,
  );
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'ranks exact and language suffixes above similar and unrelated names',
    () {
      expect(
        subtitleNameSimilarity('Episode1.mkv', 'Episode10.srt'),
        lessThan(2),
      );
      expect(subtitleNameSimilarity('Movie.2026.mkv', 'movie_2026.srt'), 3);
      expect(
        subtitleNameSimilarity('Movie.2026.mkv', 'Movie.2026.vi.srt'),
        greaterThan(2),
      );
      expect(
        subtitleNameSimilarity('Movie.2026.mkv', 'Movies.2026.srt'),
        lessThan(2),
      );
      expect(
        subtitleNameSimilarity('Movie.2026.mkv', 'Other.vtt'),
        lessThan(1),
      );
    },
  );

  test('lists only sibling subtitle files and sorts matches first', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listDirectory');
          expect((call.arguments as Map)['dirPath'], '/films');
          return [
            'F|50|0|Other.srt',
            'F|50|0|Movie.vi.vtt',
            'F|50|0|Movie.srt',
            'D|0|0|Folder.srt',
            'F|50|0|Movie.mkv',
          ];
        });
    expect(await findSubtitleFiles(api, container, '/films/Movie.mkv'), [
      '/films/Movie.srt',
      '/films/Movie.vi.vtt',
      '/films/Other.srt',
    ]);
  });

  test('decodes UTF-8 SRT and UTF-16 in either byte order', () {
    for (final bytes in [
      Uint8List.fromList(utf8.encode(_srt)),
      Uint8List.fromList([
        0xff,
        0xfe,
        ..._srt.codeUnits.expand((c) => [c & 255, c >> 8]),
      ]),
      Uint8List.fromList([
        0xfe,
        0xff,
        ..._srt.codeUnits.expand((c) => [c >> 8, c & 255]),
      ]),
    ]) {
      final sub = ExternalSubtitle.parse('Movie.SRT', bytes);
      expect(sub.track.captionAt(const Duration(seconds: 2))?.text, 'Xin chào');
      expect(sub.track.captionAt(const Duration(seconds: 4)), isNull);
    }
  });

  test('decodes WebVTT cue settings', () {
    final sub = ExternalSubtitle.parse(
      'Movie.vtt',
      Uint8List.fromList(
        utf8.encode('WEBVTT\n\n00:01.000 --> 00:03.000 align:start\nHello\n'),
      ),
    );
    expect(sub.track.captionAt(const Duration(seconds: 2))?.text, 'Hello');
  });

  test('rejects unsupported, malformed, or oversized subtitle files', () {
    for (final name in ['Movie.ass', 'Movie.srt']) {
      expect(
        () => ExternalSubtitle.parse(name, Uint8List.fromList([1, 2])),
        throwsFormatException,
      );
    }
    expect(
      () =>
          ExternalSubtitle.parse('Movie.srt', Uint8List(maxSubtitleBytes + 1)),
      throwsFormatException,
    );
  });

  test('checks sibling size before requesting bytes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getFileSize');
          return maxSubtitleBytes + 1;
        });
    await expectLater(
      readSubtitleFile(api, container, 'Movie.srt'),
      throwsFormatException,
    );
  });

  test('keeps subtitle selection when a video is renamed', () {
    final manager = VideoPlaybackManager();
    final sub = ExternalSubtitle.parse(
      'Movie.srt',
      Uint8List.fromList(utf8.encode(_srt)),
    );
    manager.selectExternalSubtitle('Movie.mkv', sub);
    manager.renameFile('Movie.mkv', 'Renamed.mkv');
    expect(manager.externalSubtitles.value['Renamed.mkv'], same(sub));
    expect(manager.externalSubtitles.value.containsKey('Movie.mkv'), isFalse);
    expect(manager.isSubtitleAvailable('Renamed.mkv'), isTrue);
    manager.dispose();
  });
}
