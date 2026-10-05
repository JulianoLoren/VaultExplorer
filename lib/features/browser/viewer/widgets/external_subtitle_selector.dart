import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/services/session_lock_controller.dart';

import '../external_subtitles.dart';
import '../video_playback_manager.dart';

class ExternalSubtitleSelector extends ConsumerStatefulWidget {
  final MountedContainer container;
  final String video;
  final VideoPlaybackManager playbackManager;
  final VoidCallback onSelected;

  const ExternalSubtitleSelector({
    super.key,
    required this.container,
    required this.video,
    required this.playbackManager,
    required this.onSelected,
  });

  @override
  ConsumerState<ExternalSubtitleSelector> createState() =>
      _ExternalSubtitleSelectorState();
}

class _ExternalSubtitleSelectorState
    extends ConsumerState<ExternalSubtitleSelector> {
  List<String> _files = [];
  bool _loading = true;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final files = await findSubtitleFiles(
        ref.read(vaultFileIoApiProvider),
        widget.container,
        widget.video,
      );
      if (mounted) setState(() => _files = files);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(String? path) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final api = ref.read(vaultFileIoApiProvider);
      final ExternalSubtitle subtitle;
      if (path == null) {
        final lock = ref.read(sessionLockControllerProvider);
        lock.suppressLock();
        final ({String name, Uint8List bytes})? picked;
        try {
          picked = await api.pickSubtitleFile();
        } finally {
          lock.unsuppressLock();
        }
        if (picked == null) return;
        subtitle = ExternalSubtitle.parse(picked.name, picked.bytes);
      } else {
        subtitle = await readSubtitleFile(api, widget.container, path);
      }
      if (!mounted) return;
      widget.playbackManager.selectExternalSubtitle(widget.video, subtitle);
      widget.onSelected();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.playbackManager.externalSubtitles,
    builder: (context, selections, _) {
      final selected = selections[widget.video];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(),
          Text(
            context.l10n.subtitleFilesHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_loading || _busy) const LinearProgressIndicator(),
          if (_failed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.l10n.subtitleLoadError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!_loading && _files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(context.l10n.noSubtitleFilesLabel),
            ),
          for (final file in _files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.subtitles_outlined),
              title: Text(p.posix.basename(file)),
              trailing: selected?.sourcePath == file
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: _busy ? null : () => _select(file),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open_rounded),
            title: Text(context.l10n.browseSubtitleFileLabel),
            subtitle: selected == null ? null : Text(selected.name),
            onTap: _busy ? null : () => _select(null),
          ),
        ],
      );
    },
  );
}
