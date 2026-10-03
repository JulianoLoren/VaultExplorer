import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/data/services/app_settings_service.dart';

// AppSettingsService keeps the raw settings blob in memory (see
// AppSettingsService._cachedBlob). These pin down the behavior callers rely
// on: fewer storage reads, but never stale data and never shared instances.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aeidolon.vaultexplorer/engine');
  const blobKey = 'app_settings_blob_v1';
  late int blobReads;
  late String blob;

  setUp(() {
    blobReads = 0;
    blob = jsonEncode(AppSettings().copyWith(autoLockMins: 7).toJson());
    AppSettingsService.invalidateCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readSecure' &&
          (call.arguments as Map)['key'] == blobKey) {
        blobReads++;
        return blob;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppSettingsService.invalidateCache();
  });

  test('loadSettings reads the blob once, then serves it from memory', () async {
    const service = AppSettingsService();

    final first = await service.loadSettings();
    final second = await service.loadSettings();

    expect(blobReads, 1);
    expect(first.autoLockMins, 7);
    expect(second.autoLockMins, 7);
  });

  test('each call gets its own AppSettings instance', () async {
    const service = AppSettingsService();

    final first = await service.loadSettings();
    first.autoLockMins = 99; // callers mutate what they get back
    final second = await service.loadSettings();

    expect(second.autoLockMins, 7);
    expect(identical(first, second), isFalse);
  });

  test('saveSettings drops the cache so the next load re-reads storage',
      () async {
    const service = AppSettingsService();
    await service.loadSettings();
    expect(blobReads, 1);

    await service.saveSettings(AppSettings());
    await service.loadSettings();

    expect(blobReads, 2);
  });

  test('invalidateCache forces the next load to hit storage', () async {
    const service = AppSettingsService();
    await service.loadSettings();

    AppSettingsService.invalidateCache();
    await service.loadSettings();

    expect(blobReads, 2);
  });
}
