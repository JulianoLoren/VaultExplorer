import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultexplorer/core/api/vault_engine_types.dart';
import 'package:vaultexplorer/core/filesystem/local_storage_container.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/models/thumbnail_cache_mode.dart';
import 'package:vaultexplorer/features/browser/viewer/media_viewer_screen.dart';
import 'package:vaultexplorer/features/browser/viewer/pdf_viewer_screen.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_screen.dart';

/// Presents an ACTION_VIEW/ACTION_EDIT request after the app's normal lock
/// gate has completed. Android retains the source app's URI grant while this
/// screen is open; content is streamed directly from that provider.
Future<void> presentExternalFileOpen(
  BuildContext context,
  WidgetRef ref,
  ExternalFileOpenRequest request,
) async {
  try {
    final uri = Uri.tryParse(request.uri);
    if (uri == null) return;

    final MountedContainer container;
    final String filePath;
    if (uri.scheme == 'content') {
      container = buildExternalDocumentContainer(
        uri: request.uri,
        displayName: request.displayName,
        canWrite: request.canWrite,
      );
      filePath = request.displayName;
    } else if (uri.scheme == 'file') {
      final path = uri.toFilePath();
      container = buildLocalStorageContainer(
        rootPath: p.dirname(path),
        displayName: request.displayName,
        readOnly: !request.canWrite,
      );
      filePath = p.basename(path);
    } else {
      return;
    }

    switch (request.viewer) {
      case 'editor':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                TextEditorScreen(container: container, filePath: filePath),
          ),
        );
        break;
      case 'media':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              container: container,
              mediaFiles: [filePath],
              initialIndex: 0,
              thumbnailCacheMode: ThumbnailCacheMode.disabled,
              isExternalOpen: true,
            ),
          ),
        );
        break;
      case 'pdf':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                PdfViewerScreen(container: container, filePath: filePath),
          ),
        );
        break;
    }
  } finally {
    await ref
        .read(vaultLifecycleApiProvider)
        .acknowledgeExternalFileOpen(request.id);
  }
}
