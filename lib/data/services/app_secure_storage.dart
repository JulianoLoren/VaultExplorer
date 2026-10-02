import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:vaultexplorer/core/utils/ve_log.dart';

part 'app_secure_storage.g.dart';

@Riverpod(keepAlive: true)
AppSecureStorage appSecureStorage(Ref ref) => const AppSecureStorage();

class AppSecureStorage {
  final MethodChannel _channel;

  const AppSecureStorage([
    this._channel = const MethodChannel('com.aeidolon.vaultexplorer/engine'),
  ]);

  static const AppSecureStorage instance = AppSecureStorage();

  Future<String?> read({required String key}) async {
    return await _channel.invokeMethod<String>('readSecure', {'key': key});
  }

  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      await delete(key: key);
      return;
    }
    final ok = await _channel.invokeMethod<bool>('writeSecure', {'key': key, 'value': value});
    // The native side answers false (not an exception) when Keystore
    // encryption or the prefs commit fails, so a lost write used to look
    // like a successful one.
    if (ok != true) {
      VeLog.w('AppSecureStorage', 'writeSecure did not persist a value (result=$ok)', ok ?? 'null');
    }
  }

  Future<void> delete({required String key}) async {
    await _channel.invokeMethod<bool>('deleteSecure', {'key': key});
  }

  Future<void> deleteAll() async {
    await _channel.invokeMethod<bool>('deleteAllSecure');
  }

  Future<Map<String, String>> readAll() async {
    final result = await _channel.invokeMapMethod<String, String>('readAllSecure');
    return result ?? <String, String>{};
  }

  Future<bool> containsKey({required String key}) async {
    final result = await _channel.invokeMethod<bool>('containsKeySecure', {'key': key});
    return result ?? false;
  }
}
