import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/theme/app_theme.dart';

import '../models/edit_segment.dart';
import '../models/video_edit_math.dart';

/// The editor's timeline: a time ruler, the segments, keyframe ticks and the
/// playhead. Drag with one finger to scrub, pinch to zoom (and pan while
/// zoomed), tap to seek / select the segment under the finger.
///
/// It owns only its zoom window; the playhead comes in as a listenable so
/// playback can move it without rebuilding the rest of the editor.
class VideoTimeline extends StatefulWidget {
  const VideoTimeline({
    super.key,
    required this.durationUs,
    required this.segments,
    required this.selectedId,
    required this.mode,
    required this.keyframes,
    required this.snappedFor,
    required this.playheadUs,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onTapAt,
  });

  final int durationUs;
  final List<EditSegment> segments;
  final String? selectedId;
  final VideoEditMode mode;
  final List<int> keyframes;

  /// What the cutter will really export for a segment (after keyframe snapping).
  final TimeRange Function(EditSegment segment) snappedFor;
  final ValueListenable<int> playheadUs;

  final VoidCallback onScrubStart;
  final ValueChanged<int> onScrub;
  final VoidCallback onScrubEnd;
  final ValueChanged<int> onTapAt;

  @override
  State<VideoTimeline> createState() => VideoTimelineState();
}

class VideoTimelineState extends State<VideoTimeline> {
  static const double _rulerHeight = 20;
  static const double _trackHeight = 44;
  static const double _height = 84;
  static const int _maxZoomSpanUs = 1000000; // most zoomed-in: 1 s across the width

  late int _viewStartUs = 0;
  late int _viewSpanUs = _fullSpan;
  double _width = 1;

  // Gesture bookkeeping.
  bool _gestureActive = false;
  bool _scrubbing = false;
  bool _multiTouch = false;
  int _gestureSpanUs = 0;
  int _focalUs = 0;

  int get _fullSpan => math.max(1, widget.durationUs);
  int get _minSpanUs => math.min(_fullSpan, _maxZoomSpanUs);

  @override
  void initState() {
    super.initState();
    widget.playheadUs.addListener(_followPlayhead);
  }

  @override
  void didUpdateWidget(VideoTimeline old) {
    super.didUpdateWidget(old);
    if (old.playheadUs != widget.playheadUs) {
      old.playheadUs.removeListener(_followPlayhead);
      widget.playheadUs.addListener(_followPlayhead);
    }
  }

  @override
  void dispose() {
    widget.playheadUs.removeListener(_followPlayhead);
    super.dispose();
  }

  // ── Zoom window ────────────────────────────────────────────────────────

  int _clampStart(int start, int span) =>
      start.clamp(0, math.max(0, _fullSpan - span)).toInt();

  int _clampUs(int us) => us.clamp(0, widget.durationUs).toInt();

  int _xToUs(double x) => (_viewStartUs + (x / _width) * _viewSpanUs).round();

  /// Zooms by [factor] (>1 zooms in) around the playhead, or the window
  /// centre when the playhead is off-screen.
  void zoomBy(double factor) {
    final playhead = widget.playheadUs.value;
    final visible = playhead >= _viewStartUs && playhead <= _viewStartUs + _viewSpanUs;
    final anchorUs = visible ? playhead : _viewStartUs + _viewSpanUs ~/ 2;
    final frac = (anchorUs - _viewStartUs) / _viewSpanUs;
    final span = (_viewSpanUs / factor).round().clamp(_minSpanUs, _fullSpan).toInt();
    setState(() {
      _viewSpanUs = span;
      _viewStartUs = _clampStart((anchorUs - frac * span).round(), span);
    });
  }

  void resetZoom() => setState(() {
        _viewStartUs = 0;
        _viewSpanUs = _fullSpan;
      });

  bool get isZoomed => _viewSpanUs < _fullSpan;

  /// Keeps the playhead on screen during playback and after seeks made with
  /// the buttons (not while the user's finger is on the timeline).
  void _followPlayhead() {
    if (_gestureActive || !isZoomed || !mounted) return;
    final p = widget.playheadUs.value;
    if (p >= _viewStartUs && p <= _viewStartUs + _viewSpanUs) return;
    setState(() {
      _viewStartUs = _clampStart(p - (_viewSpanUs * 0.1).round(), _viewSpanUs);
    });
  }

  // ── Gestures ───────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _gestureActive = true;
    _multiTouch = d.pointerCount > 1;
    _gestureSpanUs = _viewSpanUs;
    _focalUs = _xToUs(d.localFocalPoint.dx);
    if (!_multiTouch) {
      _scrubbing = true;
      widget.onScrubStart();
      widget.onScrub(_clampUs(_focalUs));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount > 1) {
      if (_scrubbing) {
        _scrubbing = false;
        widget.onScrubEnd();
      }
      _multiTouch = true;
      final scale = d.horizontalScale <= 0 ? 1.0 : d.horizontalScale;
      final span = (_gestureSpanUs / scale).round().clamp(_minSpanUs, _fullSpan).toInt();
      final start = (_focalUs - (d.localFocalPoint.dx / _width) * span).round();
      setState(() {
        _viewSpanUs = span;
        _viewStartUs = _clampStart(start, span);
      });
    } else if (_scrubbing) {
      widget.onScrub(_clampUs(_xToUs(d.localFocalPoint.dx)));
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_scrubbing) {
      _scrubbing = false;
      widget.onScrubEnd();
    }
    _multiTouch = false;
    _gestureActive = false;
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final segmentColor = widget.mode == VideoEditMode.keep ? cs.primary : cs.error;
    final style = context.typography.labelSmall?.copyWith(color: cs.onSurfaceVariant) ??
        TextStyle(fontSize: 10, color: cs.onSurfaceVariant);

    return Semantics(
      label: context.l10n.videoEditorTimelineLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = math.max(1, constraints.maxWidth);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => widget.onTapAt(_clampUs(_xToUs(d.localPosition.dx))),
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ValueListenableBuilder<int>(
              valueListenable: widget.playheadUs,
              builder: (context, playhead, _) => CustomPaint(
                size: Size(_width, _height),
                painter: _TimelinePainter(
                  durationUs: widget.durationUs,
                  viewStartUs: _viewStartUs,
                  viewSpanUs: _viewSpanUs,
                  segments: widget.segments,
                  selectedId: widget.selectedId,
                  keyframes: widget.keyframes,
                  snappedFor: widget.snappedFor,
                  playheadUs: playhead,
                  trackColor: cs.surfaceContainerHighest,
                  segmentColor: segmentColor,
                  snapColor: cs.tertiary,
                  tickColor: cs.outline,
                  playheadColor: cs.onSurface,
                  labelStyle: style,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.durationUs,
    required this.viewStartUs,
    required this.viewSpanUs,
    required this.segments,
    required this.selectedId,
    required this.keyframes,
    required this.snappedFor,
    required this.playheadUs,
    required this.trackColor,
    required this.segmentColor,
    required this.snapColor,
    required this.tickColor,
    required this.playheadColor,
    required this.labelStyle,
  });

  final int durationUs;
  final int viewStartUs;
  final int viewSpanUs;
  final List<EditSegment> segments;
  final String? selectedId;
  final List<int> keyframes;
  final TimeRange Function(EditSegment) snappedFor;
  final int playheadUs;
  final Color trackColor;
  final Color segmentColor;
  final Color snapColor;
  final Color tickColor;
  final Color playheadColor;
  final TextStyle labelStyle;

  static const List<int> _stepsUs = [
    100000, 200000, 500000, 1000000, 2000000, 5000000, 10000000, 15000000,
    30000000, 60000000, 120000000, 300000000, 600000000, 900000000,
    1800000000, 3600000000, 7200000000,
  ];

  double _x(int us, double width) => (us - viewStartUs) / viewSpanUs * width;

  int _lowerBound(int t) {
    var lo = 0;
    var hi = keyframes.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const rulerH = VideoTimelineState._rulerHeight;
    const trackH = VideoTimelineState._trackHeight;
    const trackTop = rulerH + 4;
    final w = size.width;

    // Track.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, trackTop, w, trackH),
        const Radius.circular(8),
      ),
      Paint()..color = trackColor,
    );

    _paintRuler(canvas, w);

    // Segments.
    for (final s in segments) {
      final x0 = _x(s.startUs, w);
      final x1 = _x(s.endUs, w);
      if (x1 < 0 || x0 > w) continue;
      final isSelected = s.id == selectedId;
      final rect = Rect.fromLTRB(
        math.max(x0, 0.0),
        trackTop,
        math.min(x1, w),
        trackTop + trackH,
      );
      canvas.drawRect(
        rect,
        Paint()..color = segmentColor.withValues(alpha: isSelected ? 0.55 : 0.3),
      );
      if (isSelected) {
        canvas.drawRect(
          rect.deflate(1),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = segmentColor,
        );
        final handle = Paint()..color = segmentColor;
        if (x0 >= 0 && x0 <= w) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x0 - 1, trackTop - 2, 5, trackH + 4),
              const Radius.circular(2),
            ),
            handle,
          );
        }
        if (x1 >= 0 && x1 <= w) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x1 - 4, trackTop - 2, 5, trackH + 4),
              const Radius.circular(2),
            ),
            handle,
          );
        }
      }
    }

    // Keyframe ticks -- only once they're far enough apart to be readable.
    if (keyframes.isNotEmpty) {
      final lo = _lowerBound(viewStartUs);
      final hi = _lowerBound(viewStartUs + viewSpanUs + 1);
      final count = hi - lo;
      if (count > 0 && w / count >= 4) {
        final tick = Paint()
          ..color = tickColor.withValues(alpha: 0.8)
          ..strokeWidth = 1;
        for (var i = lo; i < hi; i++) {
          final x = _x(keyframes[i], w);
          canvas.drawLine(
            Offset(x, trackTop + trackH - 9),
            Offset(x, trackTop + trackH),
            tick,
          );
        }
      }
    }

    // What will really be exported (snapped to keyframes), as thin bars under the track.
    if (keyframes.isNotEmpty) {
      final snapPaint = Paint()..color = snapColor;
      for (final s in segments) {
        final r = snappedFor(s);
        final x0 = math.max(_x(r.startUs, w), 0.0);
        final x1 = math.min(_x(r.endUs, w), w);
        if (x1 <= x0) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x0, trackTop + trackH + 3, x1, trackTop + trackH + 6),
            const Radius.circular(1.5),
          ),
          snapPaint,
        );
      }
    }

    // Playhead.
    final px = _x(playheadUs, w);
    if (px >= -2 && px <= w + 2) {
      final paint = Paint()
        ..color = playheadColor
        ..strokeWidth = 2;
      canvas.drawLine(Offset(px, rulerH - 2), Offset(px, trackTop + trackH + 8), paint);
      canvas.drawCircle(Offset(px, rulerH - 2), 5, paint);
    }
  }

  void _paintRuler(Canvas canvas, double w) {
    final pxPerUs = w / viewSpanUs;
    var step = _stepsUs.last;
    for (final s in _stepsUs) {
      if (s * pxPerUs >= 70) {
        step = s;
        break;
      }
    }
    final tick = Paint()
      ..color = tickColor
      ..strokeWidth = 1;
    final first = (viewStartUs / step).ceil() * step;
    for (var t = first; t <= viewStartUs + viewSpanUs; t += step) {
      if (t > durationUs) break;
      final x = _x(t, w);
      canvas.drawLine(Offset(x, 12), Offset(x, 19), tick);
      final tp = TextPainter(
        text: TextSpan(
          text: formatTimecode(t, millis: step < 1000000),
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (x + 3 + tp.width <= w) tp.paint(canvas, Offset(x + 3, 0));
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.playheadUs != playheadUs ||
      old.viewStartUs != viewStartUs ||
      old.viewSpanUs != viewSpanUs ||
      old.selectedId != selectedId ||
      old.segmentColor != segmentColor ||
      !identical(old.segments, segments) ||
      !identical(old.keyframes, keyframes);
}
