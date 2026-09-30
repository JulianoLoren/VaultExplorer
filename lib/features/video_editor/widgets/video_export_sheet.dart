import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/theme/app_theme.dart';
import 'package:vaultexplorer/core/widgets/sheets/app_bottom_sheet.dart';
import 'package:vaultexplorer/core/widgets/sheets/sheet_option_tile.dart';

import '../models/video_edit_math.dart';

/// What the user chose in [VideoExportSheet].
class VideoExportChoice {
  /// Join every clip into one file (true) or write one file per clip (false).
  /// Meaningless, and false, when there is only one clip.
  final bool merge;
  const VideoExportChoice({required this.merge});
}

/// Bottom sheet shown when the user taps Export. It only decides *how* to
/// export; naming and the write itself happen in the caller.
class VideoExportSheet extends StatelessWidget {
  final int clipCount;
  final int totalDurationUs;

  const VideoExportSheet({
    super.key,
    required this.clipCount,
    required this.totalDurationUs,
  });

  static Future<VideoExportChoice?> show(
    BuildContext context, {
    required int clipCount,
    required int totalDurationUs,
  }) {
    return showModalBottomSheet<VideoExportChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VideoExportSheet(
        clipCount: clipCount,
        totalDurationUs: totalDurationUs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cs = context.colors;
    final text = context.typography;

    return AppBottomSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(l10n.videoEditorExportTitle, style: text.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              l10n.videoEditorExportSummary(
                clipCount,
                formatTimecode(totalDurationUs, millis: false),
              ),
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (clipCount <= 1)
            SheetOptionTile(
              icon: Icons.content_cut_rounded,
              title: l10n.videoEditorExportSingle,
              subtitle: l10n.videoEditorExportSingleHint,
              onTap: () => Navigator.pop(
                context,
                const VideoExportChoice(merge: false),
              ),
            )
          else ...[
            SheetOptionTile(
              icon: Icons.merge_type_rounded,
              title: l10n.videoEditorExportMerge,
              subtitle: l10n.videoEditorExportMergeHint,
              onTap: () => Navigator.pop(
                context,
                const VideoExportChoice(merge: true),
              ),
            ),
            SheetOptionTile(
              icon: Icons.video_library_outlined,
              title: l10n.videoEditorExportSeparate,
              subtitle: l10n.videoEditorExportSeparateHint(clipCount),
              onTap: () => Navigator.pop(
                context,
                const VideoExportChoice(merge: false),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              l10n.videoEditorLosslessNote,
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
