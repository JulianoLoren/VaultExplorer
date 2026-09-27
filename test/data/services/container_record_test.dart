import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/data/services/container_repository.dart';

void main() {
  group('ContainerRecord isExemptFromGlobalLock', () {
    test('is false when container is at App Default (autoCloseMins == 0, autoCloseNever == false)', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: 'Default Vault',
        autoCloseMins: 0,
        autoCloseNever: false,
      );
      expect(record.isExemptFromGlobalLock, isFalse);
    });

    test('is true when container explicitly has autoCloseNever set to true', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: 'Never Lock Vault',
        autoCloseMins: 0,
        autoCloseNever: true,
      );
      expect(record.isExemptFromGlobalLock, isTrue);
    });

    test('is true when container explicitly has autoCloseMins > 0 (e.g. 1 minute)', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: '1-Min Vault',
        autoCloseMins: 1,
        autoCloseNever: false,
      );
      expect(record.isExemptFromGlobalLock, isTrue);
    });

    test('is true when container explicitly has custom duration (e.g. 15 minutes)', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: '15-Min Vault',
        autoCloseMins: 15,
        autoCloseNever: false,
      );
      expect(record.isExemptFromGlobalLock, isTrue);
    });

    test('is true when container explicitly has autoCloseImmediately set to true', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: 'Immediate Lock Vault',
        autoCloseMins: 0,
        autoCloseImmediately: true,
      );
      expect(record.isExemptFromGlobalLock, isTrue);
    });
  });

  group('ContainerRecord.autoCloseImmediately', () {
    test('defaults to false, same as pre-upgrade records with no key for it', () {
      const record = ContainerRecord(uri: 'file:///vault.hc', label: 'Default Vault');
      expect(record.autoCloseImmediately, isFalse);

      final fromLegacyJson = ContainerRecord.fromJson({
        'uri': 'file:///vault.hc',
        'label': 'Default Vault',
        'autoCloseMins': 0,
        'autoCloseNever': false,
      });
      expect(fromLegacyJson.autoCloseImmediately, isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      const record = ContainerRecord(
        uri: 'file:///vault.hc',
        label: 'Immediate Lock Vault',
        autoCloseImmediately: true,
      );

      final restored = ContainerRecord.fromJson(record.toJson());

      expect(restored.autoCloseImmediately, isTrue);
      expect(restored.autoCloseNever, isFalse);
      expect(restored.autoCloseMins, 0);
    });

    test('copyWith can set and clear it independently of autoCloseNever', () {
      const record = ContainerRecord(uri: 'file:///vault.hc', label: 'Vault');

      final immediate = record.copyWith(autoCloseImmediately: true);
      expect(immediate.autoCloseImmediately, isTrue);
      expect(immediate.autoCloseNever, isFalse);

      final never = immediate.copyWith(autoCloseImmediately: false, autoCloseNever: true);
      expect(never.autoCloseImmediately, isFalse);
      expect(never.autoCloseNever, isTrue);
    });
  });
}
