import 'package:flutter/foundation.dart';

/// A half-open time range `[startUs, endUs)` in microseconds -- the unit the
/// native side (MediaExtractor) uses, so no precision is lost crossing the
/// channel.
typedef TimeRange = ({int startUs, int endUs});

/// What the segments on the timeline mean when exporting.
///
/// "invert cut segments" switch: with [keep] the
/// segments are the parts you want; with [cutOut] they are the parts you
/// want *removed*, and the video is exported as everything in between.
enum VideoEditMode { keep, cutOut }

/// One segment on the editor timeline.
@immutable
class EditSegment {
  final String id;
  final int startUs;
  final int endUs;

  const EditSegment({
    required this.id,
    required this.startUs,
    required this.endUs,
  });

  int get lengthUs => endUs - startUs;

  bool containsUs(int t) => t >= startUs && t < endUs;

  EditSegment copyWith({int? startUs, int? endUs}) => EditSegment(
        id: id,
        startUs: startUs ?? this.startUs,
        endUs: endUs ?? this.endUs,
      );

  TimeRange get range => (startUs: startUs, endUs: endUs);

  @override
  bool operator ==(Object other) =>
      other is EditSegment &&
      other.id == id &&
      other.startUs == startUs &&
      other.endUs == endUs;

  @override
  int get hashCode => Object.hash(id, startUs, endUs);

  @override
  String toString() => 'EditSegment($id, $startUs..$endUs)';
}
