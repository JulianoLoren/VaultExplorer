import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/data/models/media_viewer_toolbar_config.dart';

void main() {
  group('MediaViewerToolbarConfig swipeToSeekEnabled', () {
    test('defaults to false in defaults() factory', () {
      final config = MediaViewerToolbarConfig.defaults();
      expect(config.swipeToSeekEnabled, isFalse);
    });

    test('defaults to false when unassigned in constructor', () {
      const config = MediaViewerToolbarConfig();
      expect(config.swipeToSeekEnabled, isFalse);
    });

    test('copyWith updates swipeToSeekEnabled', () {
      final config = MediaViewerToolbarConfig.defaults();
      final updated = config.copyWith(swipeToSeekEnabled: true);
      expect(updated.swipeToSeekEnabled, isTrue);

      final reset = updated.copyWith(swipeToSeekEnabled: false);
      expect(reset.swipeToSeekEnabled, isFalse);
    });

    test('serializes and deserializes swipeToSeekEnabled in JSON', () {
      final config = MediaViewerToolbarConfig.defaults().copyWith(
        swipeToSeekEnabled: true,
      );
      final json = config.toJson();
      expect(json['swipeToSeekEnabled'], isTrue);

      final restored = MediaViewerToolbarConfig.fromJson(json);
      expect(restored.swipeToSeekEnabled, isTrue);
    });

    test('fromJson falls back to false when key is missing', () {
      final json = <String, dynamic>{
        'showProgressBar': true,
      };
      final config = MediaViewerToolbarConfig.fromJson(json);
      expect(config.swipeToSeekEnabled, isFalse);
    });
  });
}
