// Test-only stand-in for the native HMAC (`HmacUtil.kt`).
//
// Computes real MACs with `package:crypto`, which is a dev_dependency used for
// nothing else -- the app itself no longer depends on it. That lets tests pin
// the Dart-side logic (TOTP step counters and truncation, Bitwarden's HKDF and
// MAC wiring) against real values, while the native primitive itself is
// checked against the published RFC vectors by `HmacUtilTest` on the JVM.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as reference;
import 'package:flutter/services.dart';
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';

class HmacCall {
  final Uint8List key;
  final Uint8List data;
  final HmacHash hash;
  HmacCall(this.key, this.data, this.hash);
}

class ReferenceHmacCrypto extends VaultCryptoApi {
  ReferenceHmacCrypto() : super(const MethodChannel('test/unused'));

  /// Every [hmac] request, in order.
  final hmacCalls = <HmacCall>[];

  @override
  Future<Uint8List?> hmac({
    required Uint8List key,
    required Uint8List data,
    required HmacHash hash,
  }) async {
    hmacCalls.add(HmacCall(Uint8List.fromList(key), Uint8List.fromList(data), hash));
    final algorithm = switch (hash) {
      HmacHash.sha1 => reference.sha1,
      HmacHash.sha256 => reference.sha256,
      HmacHash.sha512 => reference.sha512,
    };
    return Uint8List.fromList(reference.Hmac(algorithm, key).convert(data).bytes);
  }
}
