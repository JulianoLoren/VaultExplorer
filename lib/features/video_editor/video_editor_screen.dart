import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:vaultexplorer/core/api/vault_engine_types.dart';
import 'package:vaultexplorer/core/api/vault_video_edit_api.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/filesystem/local_storage_container.dart';
import 'package:vaultexplorer/core/filesystem/mounted_container_filesystem.dart';
import 'package:vaultexplorer/core/filesystem/name_validation.dart';
import 'package:vaultexplorer/core/filesystem/path_components.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/core/services/playback_throttle_controller.dart';
import 'package:vaultexplorer/core/theme/app_theme.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/core/utils/ve_log.dart';
import 'package:vaultexplorer/core/widgets/feedback/app_feedback.dart';
import 'package:vaultexplorer/core/widgets/feedback/inline_banner.dart';
import 'package:vaultexplorer/data/models/file_operation.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/browser/viewer/native_video_controller.dart';

import 'models/edit_segment.dart';
import 'models/video_edit_math.dart';
import 'video_edit_providers.dart';
import 'video_editor_controller.dart';
import 'widgets/video_export_sheet.dart';
import 'widgets/video_timeline.dart';

/// A simple lossless video editor: trim, cut out parts, split, and merge
/// clips without re-encoding (see `LosslessVideoCutter.kt`). The workflow
///  move the playhead, set a segment's start and end,
/// choose whether the segments are kept or cut out, export.
///
/// [filePath] is container-relative (as everywhere else in the file browser);
/// results are written next to the original as new files.
class VideoEditorScreen extends ConsumerStatefulWidget {
  final MountedContainer container;
  final String filePath;

  const VideoEditorScreen({
    super.key,
    required this.container,
    required this.filePath,
  });

  @override
  ConsumerState<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends ConsumerState<VideoEditorScreen>
    with WidgetsBindingObserver {
  static int _opCounter = DateTime.now().millisecondsSinceEpoch & 0x3fffffff;
  static const String _tag = 'VideoEditorScreen';

  NativeVideoController? _player;
  VideoEditorController? _editor;
  VideoProbe? _probe;
  String? _loadError;

  /// The playhead in microseconds. Follows the player, except while the user
  /// is scrubbing or a seek is still in flight, when it holds the requested
  /// position so the UI doesn't jump back.
  final ValueNotifier<int> _playhead = ValueNotifier<int>(0);
  final GlobalKey<VideoTimelineState> _timelineKey = GlobalKey<VideoTimelineState>();

  bool _scrubbing = false;
  bool _resumeAfterScrub = false;
  bool _exporting = false;

  // Seek pump: only the latest requested position is ever sent, one at a time.
  int? _pendingSeekUs;
  bool _seeking = false;
  Completer<void>? _seekIdle;

  bool get _isLocal => widget.container.isLocalStorage;

  /// Path the native side reads from: real and absolute for local storage,
  /// container-relative for a vault (same rule the media viewer follows).
  String get _nativePath =>
      _isLocal ? p.join(widget.container.uri, widget.filePath) : widget.filePath;

  String get _fileName => widget.filePath.split('/').last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Normal exits already went through [_shutdownPlayer] (see the PopScope
    // in build); this only catches the route being removed some other way.
    unawaited(_shutdownPlayer());
    _editor?.dispose();
    _playhead.dispose();
    super.dispose();
  }

  /// Releases the native player and clears the playback-active flag.
  ///
  /// There is one native player for the whole app, so this must finish
  /// *before* the screen pops: the media viewer re-initializes its own player
  /// as soon as the pop completes, and a `release` from this screen landing
  /// after that would tear the viewer's new player down.
  Future<void> _shutdownPlayer() async {
    final player = _player;
    if (player == null) return;
    _player = null;
    player.removeListener(_onPlayerChanged);
    await player.dispose();
    await PlaybackThrottleController.setActive(false);
  }

  Future<void> _onPopRequested(bool didPop, Object? result) async {
    if (didPop || _exporting) return;
    await _shutdownPlayer();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_player?.pause());
  }

  // ── Loading ────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final api = ref.read(vaultVideoEditApiProvider);
    try {
      await PlaybackThrottleController.setActive(true);
      if (!mounted) return;

      final player = NativeVideoController(
        volId: widget.container.volId,
        filePath: _nativePath,
        autoPlay: false,
        isLocalStorage: _isLocal,
      );
      _player = player;
      player.addListener(_onPlayerChanged);
      unawaited(player.initialize().catchError((Object e) {
        VeLog.w(_tag, 'Player initialization failed', e);
      }));

      final probe = await api.probe(
        volId: widget.container.volId,
        filePath: _nativePath,
        isLocalStorage: _isLocal,
      );
      if (!mounted) return;
      if (probe.durationUs <= 0) {
        throw const VideoEditException('PROBE_FAILED', 'Unknown video length');
      }

      final editor = VideoEditorController(
        durationUs: probe.durationUs,
        keyframesUs: probe.keyframesUs,
        keyframesComplete: probe.keyframesComplete,
      );
      setState(() {
        _probe = probe;
        _editor = editor;
      });
    } on VideoEditException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    } catch (e) {
      VeLog.w(_tag, 'Loading the video editor failed', e);
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  void _onPlayerChanged() {
    if (_scrubbing || _seeking) return;
    final player = _player;
    final editor = _editor;
    if (player == null) return;
    var us = player.value.position.inMicroseconds;
    if (editor != null && us > editor.durationUs) us = editor.durationUs;
    if (us != _playhead.value) _playhead.value = us;
  }

  // ── Seeking / transport ────────────────────────────────────────────────

  Future<void> _seekToUs(int us) {
    final editor = _editor;
    final t = editor == null ? us : us.clamp(0, editor.durationUs).toInt();
    _playhead.value = t;
    return _requestSeek(t);
  }

  Future<void> _requestSeek(int us) {
    _pendingSeekUs = us;
    if (_seeking) return _seekIdle!.future;
    _seeking = true;
    _seekIdle = Completer<void>();
    unawaited(_runSeekLoop());
    return _seekIdle!.future;
  }

  Future<void> _runSeekLoop() async {
    try {
      while (_pendingSeekUs != null) {
        final us = _pendingSeekUs!;
        _pendingSeekUs = null;
        final player = _player;
        if (player == null || player.isDisposed) break;
        // The player seeks in whole milliseconds; rounding down would land one
        // frame *before* a keyframe that sits mid-millisecond.
        await player.seekTo(Duration(milliseconds: (us + 999) ~/ 1000));
      }
    } catch (e) {
      VeLog.w(_tag, 'Seek failed', e);
    } finally {
      _seeking = false;
      _seekIdle!.complete();
    }
  }

  void _onScrubStart() {
    _scrubbing = true;
    _resumeAfterScrub = _player?.value.isPlaying ?? false;
    if (_resumeAfterScrub) unawaited(_player?.pause());
  }

  void _onScrub(int us) => unawaited(_seekToUs(us));

  void _onScrubEnd() {
    _scrubbing = false;
    if (_resumeAfterScrub) unawaited(_player?.play());
    _resumeAfterScrub = false;
  }

  void _onTimelineTap(int us) {
    _editor?.selectAt(us);
    unawaited(_seekToUs(us));
  }

  Future<void> _togglePlay() async {
    final player = _player;
    final editor = _editor;
    if (player == null || editor == null) return;
    if (player.value.isPlaying) {
      await player.pause();
      return;
    }
    if (_playhead.value >= editor.durationUs - 200000) {
      await _seekToUs(0);
    }
    await player.play();
  }

  void _step(int deltaUs) => unawaited(_seekToUs(_playhead.value + deltaUs));

  void _jumpKeyframe({required bool forward}) {
    final editor = _editor;
    if (editor == null) return;
    final from = _playhead.value;
    final target = forward
        ? (editor.nextKeyframe(from) ?? editor.durationUs)
        : (editor.previousKeyframe(from) ?? 0);
    unawaited(_seekToUs(target));
  }

  // ── Segment edits ──────────────────────────────────────────────────────

  void _toast(String message, {AppBannerTone tone = AppBannerTone.info}) {
    if (!mounted) return;
    showAppSnackBar(context, message: message, tone: tone);
  }

  void _setStart() {
    if (!_editor!.setSelectedStart(_playhead.value)) {
      _toast(context.l10n.videoEditorBoundaryInvalid);
    }
  }

  void _setEnd() {
    if (!_editor!.setSelectedEnd(_playhead.value)) {
      _toast(context.l10n.videoEditorBoundaryInvalid);
    }
  }

  void _addSegment() {
    if (!_editor!.addSegmentAt(_playhead.value)) {
      _toast(context.l10n.videoEditorNoRoom);
    }
  }

  void _splitSegment() {
    if (!_editor!.splitAt(_playhead.value)) {
      _toast(context.l10n.videoEditorNoRoom);
    }
  }

  // ── Export ─────────────────────────────────────────────────────────────

  Future<void> _onExport() async {
    final editor = _editor;
    final probe = _probe;
    if (editor == null || probe == null || _exporting) return;
    final l10n = context.l10n;

    if (widget.container.readOnly) {
      _toast(l10n.videoEditorReadOnly, tone: AppBannerTone.error);
      return;
    }
    if (!editor.canExport) {
      _toast(l10n.videoEditorNothingToExport);
      return;
    }

    await _player?.pause();
    if (!mounted) return;

    final choice = await VideoExportSheet.show(
      context,
      clipCount: editor.plannedRanges.length,
      totalDurationUs: editor.totalSnappedUs,
    );
    if (choice == null || !mounted) return;

    final ranges = editor.exportRanges(merge: choice.merge);
    final outputCount = choice.merge ? 1 : ranges.length;

    // Name the outputs next to the original, never colliding with anything
    // already in the folder or with each other.
    final container = widget.container;
    final slash = widget.filePath.lastIndexOf('/');
    final dirPath = slash == -1 ? '' : widget.filePath.substring(0, slash);

    var existing = <RawEntry>[];
    try {
      final raw = await ref.read(vaultFileIoApiProvider).listDirectory(container, dirPath);
      if (raw != null) existing = RawEntry.parseAll(raw);
    } catch (e) {
      VeLog.w(_tag, 'Directory listing failed at ${VeLog.censorUri(dirPath)} while naming exports', e);
    }
    if (!mounted) return;

    final fsType = resolveFilesystemType(container);
    final names = planOutputNames(
      sourceFileName: _fileName,
      extension: probe.outputExtension,
      count: outputCount,
      existingLowercase: {for (final e in existing) e.name.toLowerCase()},
      unique: FileOperationService.makeUniqueName,
    );

    final relativePaths = <String>[];
    for (final name in names) {
      final built = PathComponents(
        parentSegments: dirPath.isEmpty ? const [] : dirPath.split('/'),
        name: name,
        type: EntryType.file,
        fsType: fsType,
      ).validateAndBuild(l10n);
      switch (built) {
        case PathBuildFailure(:final issues):
          _toast(
            l10n.videoEditorExportFailed(issues.first.message),
            tone: AppBannerTone.error,
          );
          return;
        case PathBuildSuccess(:final path):
          relativePaths.add(path);
      }
    }
    final nativeOutputs = _isLocal
        ? [for (final r in relativePaths) p.join(container.uri, r)]
        : relativePaths;

    await _runExport(
      ranges: ranges,
      merge: choice.merge,
      outputPaths: nativeOutputs,
      outputCount: outputCount,
    );
  }

  Future<void> _runExport({
    required List<TimeRange> ranges,
    required bool merge,
    required List<String> outputPaths,
    required int outputCount,
  }) async {
    final api = ref.read(vaultVideoEditApiProvider);
    final events = ref.read(vaultEngineEventsProvider);
    final l10n = context.l10n;
    final navigator = Navigator.of(context, rootNavigator: true);
    final opId = ++_opCounter;

    final progress = ValueNotifier<VideoEditProgress?>(null);
    void onProgress(VideoEditProgress e) {
      if (e.opId == opId) progress.value = e;
    }

    events.addVideoEditProgressListener(onProgress);
    setState(() => _exporting = true);

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _ExportProgressDialog(
          progress: progress,
          outputCount: outputCount,
          onCancel: () => unawaited(api.cancel(opId)),
        ),
      ),
    ));

    VideoExportResult? result;
    VideoEditException? failure;
    try {
      result = await api.export(
        volId: widget.container.volId,
        filePath: _nativePath,
        isLocalStorage: _isLocal,
        segmentsUs: ranges,
        merge: merge,
        outputPaths: outputPaths,
        opId: opId,
      );
    } on VideoEditException catch (e) {
      failure = e;
    } catch (e) {
      VeLog.w(_tag, 'Export failed unexpectedly', e);
      failure = VideoEditException('EXPORT_FAILED', e.toString());
    } finally {
      events.removeVideoEditProgressListener(onProgress);
    }

    if (navigator.mounted) navigator.pop(); // close the progress dialog
    if (!mounted) return;
    setState(() => _exporting = false);

    if (result != null) {
      final count = result.outputPaths.length;
      _toast(
        result.droppedAudioTracks > 0
            ? '${l10n.videoEditorSaved(count)} ${l10n.videoEditorAudioDropped}'
            : l10n.videoEditorSaved(count),
        tone: result.droppedAudioTracks > 0
            ? AppBannerTone.warning
            : AppBannerTone.success,
      );
    } else if (failure != null) {
      if (failure.cancelled) {
        _toast(l10n.videoEditorExportCancelled);
      } else {
        _toast(
          l10n.videoEditorExportFailed(failure.message),
          tone: AppBannerTone.error,
        );
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final editor = _editor;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopRequested,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (editor != null)
              ListenableBuilder(
                listenable: editor,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: l10n.undoTooltip,
                      icon: const Icon(Icons.undo_rounded),
                      onPressed: editor.canUndo ? editor.undo : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12, left: 4),
                      // The app theme gives FilledButton an infinite minimum
                      // width (for full-width sheet buttons); AppBar actions
                      // have unbounded width, so override it here or the whole
                      // app bar fails to lay out.
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                        ),
                        onPressed:
                            editor.canExport && !_exporting ? _onExport : null,
                        child: Text(l10n.videoEditorExportAction),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        body: SafeArea(child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    final cs = context.colors;
    final editor = _editor;
    final player = _player;

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: cs.error),
              const SizedBox(height: 12),
              Text(
                l10n.videoEditorLoadFailed(_loadError!),
                textAlign: TextAlign.center,
                style: context.typography.bodyMedium,
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(l10n.closeTooltip),
              ),
            ],
          ),
        ),
      );
    }
    if (editor == null || player == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final preview = _buildPreview(player);
    return ListenableBuilder(
      listenable: editor,
      builder: (context, _) {
        final controls = _buildControls(context, editor, player);
        final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
        if (landscape) {
          return Row(
            children: [
              Expanded(child: preview),
              SizedBox(
                width: 380,
                child: SingleChildScrollView(child: controls),
              ),
            ],
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              Expanded(child: preview),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.65),
                child: SingleChildScrollView(child: controls),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreview(NativeVideoController player) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_togglePlay()),
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: ValueListenableBuilder<NativeVideoValue>(
            valueListenable: player,
            builder: (context, v, _) {
              if (v.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    v.errorDescription,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                );
              }
              if (!v.isInitialized) return const CircularProgressIndicator();
              return AspectRatio(
                aspectRatio: v.aspectRatio,
                child: NativeVideoPlayerView(controller: player),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    VideoEditorController editor,
    NativeVideoController player,
  ) {
    final l10n = context.l10n;
    final cs = context.colors;
    final text = context.typography;
    final segments = editor.segments;
    final selected = editor.selected;

    final snapNote = _snapNote(context, editor, selected);
    final summaryStyle = text.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Time readout + zoom.
          Row(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: _playhead,
                builder: (context, us, _) => Text(
                  '${formatTimecode(us)} / ${formatTimecode(editor.durationUs)}',
                  style: text.labelLarge,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.videoEditorZoomOut,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.zoom_out_rounded),
                onPressed: () => _timelineKey.currentState?.zoomBy(0.5),
              ),
              IconButton(
                tooltip: l10n.videoEditorZoomIn,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.zoom_in_rounded),
                onPressed: () => _timelineKey.currentState?.zoomBy(2),
              ),
              IconButton(
                tooltip: l10n.videoEditorZoomFit,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.fit_screen_rounded),
                onPressed: () => _timelineKey.currentState?.resetZoom(),
              ),
            ],
          ),

          VideoTimeline(
            key: _timelineKey,
            durationUs: editor.durationUs,
            segments: segments,
            selectedId: editor.selectedId,
            mode: editor.mode,
            keyframes: editor.keyframes,
            snappedFor: editor.snappedFor,
            playheadUs: _playhead,
            onScrubStart: _onScrubStart,
            onScrub: _onScrub,
            onScrubEnd: _onScrubEnd,
            onTapAt: _onTimelineTap,
          ),
          const SizedBox(height: 4),

          // Transport. Scales down rather than overflowing on narrow screens.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.videoEditorPrevKeyframe,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => _jumpKeyframe(forward: false),
                ),
                _StepButton(label: '−1s', onTap: () => _step(-1000000)),
                _StepButton(label: '−0.1s', onTap: () => _step(-100000)),
                ValueListenableBuilder<NativeVideoValue>(
                  valueListenable: player,
                  builder: (context, v, _) => IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                    tooltip: l10n.mediaViewerActionPlayPause,
                    icon: Icon(
                      v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                    onPressed: () => unawaited(_togglePlay()),
                  ),
                ),
                _StepButton(label: '+0.1s', onTap: () => _step(100000)),
                _StepButton(label: '+1s', onTap: () => _step(1000000)),
                IconButton(
                  tooltip: l10n.videoEditorNextKeyframe,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => _jumpKeyframe(forward: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Segment tools.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ToolButton(
                  icon: Icons.first_page_rounded,
                  label: l10n.videoEditorSetStart,
                  onTap: selected == null ? null : _setStart,
                ),
                _ToolButton(
                  icon: Icons.last_page_rounded,
                  label: l10n.videoEditorSetEnd,
                  onTap: selected == null ? null : _setEnd,
                ),
                _ToolButton(
                  icon: Icons.add_rounded,
                  label: l10n.videoEditorAddSegment,
                  onTap: _addSegment,
                ),
                _ToolButton(
                  icon: Icons.call_split_rounded,
                  label: l10n.videoEditorSplit,
                  onTap: _splitSegment,
                ),
                _ToolButton(
                  icon: Icons.delete_outline_rounded,
                  label: l10n.videoEditorDeleteSegment,
                  onTap: selected == null ? null : editor.deleteSelected,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Keep vs cut out.
          SegmentedButton<VideoEditMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: VideoEditMode.keep,
                icon: const Icon(Icons.check_rounded),
                label: Text(l10n.videoEditorModeKeep),
              ),
              ButtonSegment(
                value: VideoEditMode.cutOut,
                icon: const Icon(Icons.content_cut_rounded),
                label: Text(l10n.videoEditorModeCutOut),
              ),
            ],
            selected: {editor.mode},
            onSelectionChanged: (s) => editor.setMode(s.first),
          ),
          const SizedBox(height: 8),

          // Segment chips.
          if (segments.isEmpty)
            Text(l10n.videoEditorNoSegments, style: summaryStyle)
          else
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: segments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final s = segments[i];
                  return ChoiceChip(
                    label: Text(
                      '${i + 1} · ${formatTimecode(s.startUs, millis: false)}'
                      '–${formatTimecode(s.endUs, millis: false)}',
                    ),
                    selected: s.id == editor.selectedId,
                    onSelected: (_) {
                      editor.select(s.id);
                      unawaited(_seekToUs(s.startUs));
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 8),

           SizedBox(
            height: MediaQuery.textScalerOf(context).scale(36.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.videoEditorOutputSummary(
                    editor.plannedRanges.length,
                    formatTimecode(editor.totalSnappedUs, millis: false),
                  ),
                  style: summaryStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (snapNote != null)
                  Text(
                    snapNote,
                    style: summaryStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "Will start at the keyframe 0:08.500" -- shown when the selected clip's
  /// real export range differs from what's drawn, so the snapping is never a
  /// surprise. Only meaningful in keep mode (in cut-out mode the selected
  /// segment is what gets removed).
  String? _snapNote(
    BuildContext context,
    VideoEditorController editor,
    EditSegment? selected,
  ) {
    if (selected == null ||
        editor.mode != VideoEditMode.keep ||
        editor.keyframes.isEmpty) {
      return null;
    }
    final snapped = editor.snappedFor(selected);
    if (snapped.startUs == selected.startUs && snapped.endUs == selected.endUs) {
      return null;
    }
    return context.l10n.videoEditorSnapNote(
      formatTimecode(snapped.startUs),
      formatTimecode(snapped.endUs),
    );
  }
}

class _StepButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _StepButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: Text(label),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: AppIconSize.small),
        label: Text(label),
      ),
    );
  }
}

/// Non-dismissible progress dialog for a running export, with Cancel.
class _ExportProgressDialog extends StatelessWidget {
  final ValueListenable<VideoEditProgress?> progress;
  final int outputCount;
  final VoidCallback onCancel;

  const _ExportProgressDialog({
    required this.progress,
    required this.outputCount,
    required this.onCancel,
  });

  /// Cutting is the long phase; the copy into the vault gets the last 15%.
  static double? _overall(VideoEditProgress? e) {
    if (e == null) return null;
    final within = e.phase == 'saving' ? 0.85 + 0.15 * e.fraction : 0.85 * e.fraction;
    return ((e.outputIndex + within) / e.outputCount).clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.videoEditorExporting),
      content: ValueListenableBuilder<VideoEditProgress?>(
        valueListenable: progress,
        builder: (context, e, _) {
          final String label;
          if (e != null && e.phase == 'saving') {
            label = l10n.videoEditorSaving;
          } else if (outputCount > 1) {
            label = l10n.videoEditorCutting((e?.outputIndex ?? 0) + 1, outputCount);
          } else {
            label = l10n.videoEditorCuttingOne;
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: _overall(e)),
              const SizedBox(height: 12),
              Text(label),
            ],
          );
        },
      ),
      actions: [
        TextButton(onPressed: onCancel, child: Text(l10n.cancel)),
      ],
    );
  }
}
