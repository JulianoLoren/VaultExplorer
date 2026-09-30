import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/features/browser/archive_preview_file.dart';

void main() {
  group('ArchivePreviewFile', () {
    test('uses the native-staged temporary path unchanged', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'archive_preview_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}archive_browse_video.mp4',
      )..writeAsBytesSync([1, 2, 3]);

      final preview = ArchivePreviewFile.fromNativePath(file.path);

      expect(preview.path, file.path);
      expect(await File(preview.path).readAsBytes(), [1, 2, 3]);
    });

    test('uses the secure-discard callback at most once', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'archive_preview_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}archive_browse_song.flac',
      )..writeAsBytesSync([1]);
      final preview = ArchivePreviewFile.fromNativePath(file.path);
      var calls = 0;

      Future<bool> secureDelete(String path) async {
        calls++;
        expect(path, preview.path);
        await File(path).delete();
        return true;
      }

      await preview.discard(secureDelete: secureDelete);
      await preview.discard(secureDelete: secureDelete);

      expect(calls, 1);
      expect(await File(preview.path).exists(), isFalse);
    });
  });
}
