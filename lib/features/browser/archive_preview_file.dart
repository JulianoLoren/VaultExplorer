import 'dart:io';

/// A short-lived, app-private copy of an archive entry for viewers that need
/// a seekable file rather than in-memory bytes.
class ArchivePreviewFile {
  final String path;
  bool _discarded = false;

  ArchivePreviewFile.fromNativePath(this.path);

  /// Deletes this preview. [secureDelete] is supplied by the native archive
  /// bridge, which verifies the cache location and wipes the file first.
  Future<void> discard({
    Future<bool> Function(String path)? secureDelete,
  }) async {
    if (_discarded) return;
    _discarded = true;

    try {
      if (secureDelete != null && await secureDelete(path)) return;
    } catch (_) {
      // Fall through to a normal best-effort delete. The native bridge creates
      // this file in the app-private cache.
    }

    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Startup cleanup will retry any file left behind after a process crash
      // or a transient filesystem failure.
    }
  }
}
