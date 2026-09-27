import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/data/services/app_settings_service.dart';
import 'package:vaultexplorer/data/services/container_repository.dart';
import 'package:vaultexplorer/features/dashboard/widgets/auto_lock_indicator.dart';

void main() {
  group('computeAutoLockPolicy', () {
    test('no record inherits the global default and is never custom', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 5);

      final policy = computeAutoLockPolicy(null, settings);

      expect(policy.status, const AutoLockAfter(5));
      expect(policy.isCustomOverride, isFalse);
    });

    test('explicit duration equal to the global default is not custom', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 5);
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseMins: 5);

      final policy = computeAutoLockPolicy(record, settings);

      expect(policy.status, const AutoLockAfter(5));
      expect(policy.isCustomOverride, isFalse);
    });

    test('explicit duration different from the global default is custom', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 5);
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseMins: 15);

      final policy = computeAutoLockPolicy(record, settings);

      expect(policy.status, const AutoLockAfter(15));
      expect(policy.isCustomOverride, isTrue);
    });

    test('explicit Never matches a global default that already never locks', () {
      final settings = AppSettings(lockContainersOnScreenLock: false);
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseNever: true);

      final policy = computeAutoLockPolicy(record, settings);

      expect(policy.status, const AutoLockNever());
      expect(policy.isCustomOverride, isFalse);
    });

    test('explicit Never is custom when the global default would still lock', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 5);
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseNever: true);

      final policy = computeAutoLockPolicy(record, settings);

      expect(policy.status, const AutoLockNever());
      expect(policy.isCustomOverride, isTrue);
    });

    test('explicit Immediately is always custom, regardless of settings', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 0);
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseImmediately: true);

      final policy = computeAutoLockPolicy(record, settings);

      expect(policy.status, const AutoLockImmediately());
      expect(policy.isCustomOverride, isTrue);
    });

    test('no override falls back to on-screen-off when the global default has no delay', () {
      final settings = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 0);

      final policy = computeAutoLockPolicy(null, settings);

      expect(policy.status, const AutoLockOnScreenOff());
      expect(policy.isCustomOverride, isFalse);
    });

    test('a matching duration becomes custom again once the global default diverges', () {
      const record = ContainerRecord(uri: 'file:///v.hc', label: 'V', autoCloseMins: 5);
      final matching = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 5);
      final diverged = AppSettings(lockContainersOnScreenLock: true, autoLockMins: 10);

      expect(computeAutoLockPolicy(record, matching).isCustomOverride, isFalse);
      expect(computeAutoLockPolicy(record, diverged).isCustomOverride, isTrue);
    });
  });

  group('AutoLockStatus equality', () {
    test('AutoLockAfter compares by minutes', () {
      expect(const AutoLockAfter(5), const AutoLockAfter(5));
      expect(const AutoLockAfter(5) == const AutoLockAfter(10), isFalse);
    });

    test('different status kinds are never equal', () {
      expect(const AutoLockNever() == const AutoLockOnScreenOff(), isFalse);
    });
  });
}
