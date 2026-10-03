import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/quick_capture_api.dart';

void main() {
  group('PendingQuickCaptureLaunch', () {
    test('take() reports a marked request once, then false', () {
      final launch = PendingQuickCaptureLaunch()
        ..markPending(appUnlockRequired: false);

      expect(launch.take(), isTrue);
      expect(launch.take(), isFalse);
    });

    test('take() is false when nothing was marked', () {
      expect(PendingQuickCaptureLaunch().take(), isFalse);
    });

    test('an owed app unlock survives take() until markAppUnlocked()', () {
      final launch = PendingQuickCaptureLaunch()
        ..markPending(appUnlockRequired: true);

      expect(launch.appUnlockRequired, isTrue);
      launch.take();
      expect(launch.appUnlockRequired, isTrue);

      launch.markAppUnlocked();
      expect(launch.appUnlockRequired, isFalse);
    });

    test('no unlock is owed when the launch did not skip the lock gate', () {
      final launch = PendingQuickCaptureLaunch()
        ..markPending(appUnlockRequired: false);

      expect(launch.appUnlockRequired, isFalse);
    });
  });
}
