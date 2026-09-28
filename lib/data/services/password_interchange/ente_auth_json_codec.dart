// Import-only codec for Ente Auth's encrypted export format and local backups
// (EnteAuthExport: Argon2id KDF + XChaCha20/XSalsa20-Poly1305).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_backup_crypto.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_import_shared.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

class EnteAuthJsonCodec implements PasswordFormatCodec {
  final VaultCryptoApi _crypto;
  const EnteAuthJsonCodec({VaultCryptoApi crypto = kDefaultBackupCrypto}) : _crypto = crypto;

  @override
  String get id => 'ente_auth';

  @override
  String get displayName => 'Ente Auth (.json)';

  @override
  String get description =>
      'Ente Auth encrypted export or local backup. Uses Argon2id and XChaCha20/XSalsa20-Poly1305.';

  @override
  bool get supportsImport => true;

  @override
  bool get supportsExport => false;

  @override
  bool get isEncrypted => true;

  @override
  bool get isOptionallyEncrypted => false;

  @override
  bool looksLikeThisFormat({required String fileName, Uint8List? bytes}) {
    final lower = fileName.toLowerCase();
    if (lower.contains('ente') && lower.endsWith('.json')) return true;
    final text = tryDecodeUtf8(bytes);
    if (text == null) return false;
    return text.contains('"kdfParams"') &&
        (text.contains('"encryptedData"') || text.contains('"encryptionNonce"'));
  }

  @override
  Future<DecodedExchange> decode(Uint8List bytes, {String? password}) async {
    if (password == null || password.isEmpty) {
      throw const PasswordFileIncorrectPasswordException();
    }
    final text = tryDecodeUtf8(bytes);
    Object? root;
    try {
      root = text == null ? null : jsonDecode(text);
    } catch (_) {}
    if (root is! Map ||
        root['kdfParams'] is! Map ||
        root['encryptedData'] == null ||
        root['encryptionNonce'] == null) {
      throw const PasswordFileFormatException('This doesn\'t look like an Ente Auth encrypted export.');
    }

    final version = root['version'];
    if (version != 1) {
      throw const PasswordFileFormatException('Unsupported Ente Auth export version.');
    }

    final kdfParams = Map<String, dynamic>.from(root['kdfParams'] as Map);
    final rawSalt = kdfParams['salt'];
    final rawMemLimit = kdfParams['memLimit'];
    final rawOpsLimit = kdfParams['opsLimit'];

    if (rawSalt is! String || rawMemLimit == null || rawOpsLimit == null) {
      throw const PasswordFileFormatException('This Ente export is missing KDF parameters.');
    }

    final salt = _decodeBase64(rawSalt);
    final memLimit = (rawMemLimit as num).toInt();
    final opsLimit = (rawOpsLimit as num).toInt();

    // libsodium crypto_pwhash: memLimit is in bytes. Argon2id C engine expects KiB.
    int memoryKiB = (memLimit / 1024).round();
    if (memoryKiB < 8) memoryKiB = 8;
    final iterations = opsLimit < 1 ? 1 : opsLimit;

    debugPrint('EnteAuthJsonCodec: Deriving Argon2id key (memoryKiB: $memoryKiB, iterations: $iterations)');

    final key = await deriveArgon2id(
      _crypto,
      password: password,
      salt: salt,
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: 1,
      outputLen: 32,
    );

    Uint8List? plain;
    try {
      final ciphertextWithMac = _decodeBase64(jsonStr(root['encryptedData']));
      final nonce = _decodeBase64(jsonStr(root['encryptionNonce']));

      // Attempt 1: Ente's newer format (libsodium XChaCha20-Poly1305 with appended tag)
      try {
        plain = await openXchacha20Poly1305(
          _crypto,
          key: key,
          nonce: nonce,
          ciphertextAndTag: ciphertextWithMac,
        );
        debugPrint('EnteAuthJsonCodec: Successfully decrypted using XChaCha20-Poly1305');
      } catch (e) {
        debugPrint('EnteAuthJsonCodec: XChaCha20-Poly1305 failed ($e). Falling back to XSalsa20-Poly1305.');
        
        // Attempt 2: Ente's older format (libsodium crypto_secretbox_easy: XSalsa20-Poly1305 with prepended tag)
        plain = _XSalsa20Poly1305.open(key, nonce, ciphertextWithMac);
        if (plain != null) {
           debugPrint('EnteAuthJsonCodec: Successfully decrypted using XSalsa20-Poly1305');
        } else {
           debugPrint('EnteAuthJsonCodec: XSalsa20-Poly1305 MAC failed. Attempting AES-GCM as final fallback.');
           
           // Attempt 3: AES-GCM just in case Ente uses it on specific platforms
           try {
             plain = await openAesGcm(
               _crypto,
               key: key,
               iv: nonce.length > 12 ? nonce.sublist(0, 12) : nonce,
               ciphertextAndTag: ciphertextWithMac,
             );
             debugPrint('EnteAuthJsonCodec: Successfully decrypted using AES-GCM');
           } catch (e2) {
             debugPrint('EnteAuthJsonCodec: AES-GCM also failed ($e2). Incorrect password.');
             throw const PasswordFileIncorrectPasswordException();
           }
        }
      }
    } finally {
      zeroizeBytes(key);
    }

    final plainText = utf8.decode(plain);
    final lines = plainText.split(RegExp(r'[\r\n]+'));

    final records = <ExchangeRecord>[];
    final warnings = <String>[];

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('"') && line.endsWith('"')) {
        try {
          line = (jsonDecode(line) as String).trim();
        } catch (_) {}
      }
      if (!line.startsWith('otpauth://')) continue;

      try {
        final record = exchangeRecordFromOtpAuthUri(
          line,
          onSkip: (reason) => warnings.add(skippedEntryWarning(_shortLabel(line), reason)),
        );
        if (record != null) records.add(record);
      } catch (e) {
        warnings.add(skippedEntryWarning(
          _shortLabel(line),
          e is FormatException ? e.message : 'the URI couldn\'t be read',
        ));
      }
    }

    if (records.isEmpty) throw noImportableEntries(warnings);
    return DecodedExchange(records, warnings: warnings);
  }

  Uint8List _decodeBase64(String str) {
    var normalized = str.trim().replaceAll(RegExp(r'\s+'), '').replaceAll('-', '+').replaceAll('_', '/');
    return base64.decode(base64.normalize(normalized));
  }

  String _shortLabel(String uri) {
    final q = uri.indexOf('?');
    final head = q >= 0 ? uri.substring(0, q) : uri;
    final slash = head.indexOf('/', 'otpauth://'.length);
    if (slash < 0) return head;
    try {
      return Uri.decodeComponent(head.substring(slash + 1));
    } catch (_) {
      return head.substring(slash + 1);
    }
  }

  @override
  Future<Uint8List> encode(List<ExchangeRecord> records, {String? password}) async =>
      throw UnsupportedError('Exporting to Ente Auth format isn\'t supported.');
}

// Pure Dart implementation of libsodium's crypto_secretbox_easy (XSalsa20-Poly1305).
// Ente uses XSalsa20, which is not available in BoringSSL/the native engine.
class _XSalsa20Poly1305 {
  static Uint8List? open(Uint8List key, Uint8List nonce, Uint8List ciphertextWithMac) {
    if (ciphertextWithMac.length < 16) {
      debugPrint('EnteAuthJsonCodec: Ciphertext too short for XSalsa20 MAC');
      return null;
    }
    
    // crypto_secretbox_easy prepends the 16-byte Poly1305 MAC to the ciphertext
    final mac = ciphertextWithMac.sublist(0, 16);
    final ciphertext = ciphertextWithMac.sublist(16);

    // Subkey generation via HSalsa20
    final subkey = _hsalsa20(key, nonce.sublist(0, 16));

    // Stream generation via Salsa20
    final inp = Uint32List(16);
    inp[0] = 0x61707865; inp[5] = 0x3320646e; inp[10] = 0x79622d32; inp[15] = 0x6b206574;
    final sk = _bytesToU32(subkey);
    inp[1] = sk[0]; inp[2] = sk[1]; inp[3] = sk[2]; inp[4] = sk[3];
    inp[11] = sk[4]; inp[12] = sk[5]; inp[13] = sk[6]; inp[14] = sk[7];
    final n = _bytesToU32(nonce.sublist(16, 24));
    inp[6] = n[0]; inp[7] = n[1];
    inp[8] = 0; inp[9] = 0;

    final block = Uint32List(16);
    
    // Block 0: Bytes 0..31 are the Poly1305 Key. Bytes 32..63 are used for XORing the message.
    _salsa20Block(block, inp);
    final blockBytes0 = _u32ToBytes(block);
    final polyKey = blockBytes0.sublist(0, 32);

    if (!_verifyPoly1305(polyKey, ciphertext, mac)) {
      debugPrint('EnteAuthJsonCodec: Poly1305 MAC verification failed.');
      return null;
    }

    final plaintext = Uint8List(ciphertext.length);
    int cPos = 0;
    int pPos = 0;
    int len = ciphertext.length;

    // Process the remaining 32 bytes from Block 0 keystream
    int take0 = len > 32 ? 32 : len;
    for (int i = 0; i < take0; i++) {
      plaintext[pPos + i] = ciphertext[cPos + i] ^ blockBytes0[32 + i];
    }
    cPos += take0;
    pPos += take0;
    len -= take0;

    // Process all subsequent blocks
    inp[8] = 1;
    while (len > 0) {
      _salsa20Block(block, inp);
      final blockBytes = _u32ToBytes(block);
      int take = len > 64 ? 64 : len;
      for (int i = 0; i < take; i++) {
        plaintext[pPos + i] = ciphertext[cPos + i] ^ blockBytes[i];
      }
      cPos += take;
      pPos += take;
      len -= take;
      
      inp[8] = (inp[8] + 1) & 0xFFFFFFFF;
      if (inp[8] == 0) inp[9] = (inp[9] + 1) & 0xFFFFFFFF;
    }
    return plaintext;
  }

  static int _rotl32(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;

  static void _quarterRound(Uint32List x, int a, int b, int c, int d) {
    x[b] ^= _rotl32((x[a] + x[d]) & 0xFFFFFFFF, 7);
    x[c] ^= _rotl32((x[b] + x[a]) & 0xFFFFFFFF, 9);
    x[d] ^= _rotl32((x[c] + x[b]) & 0xFFFFFFFF, 13);
    x[a] ^= _rotl32((x[d] + x[c]) & 0xFFFFFFFF, 18);
  }

  static void _salsa20Block(Uint32List out, Uint32List inp) {
    for (int i = 0; i < 16; i++) out[i] = inp[i];
    for (int i = 0; i < 10; i++) {
      _quarterRound(out, 0, 4, 8, 12);
      _quarterRound(out, 5, 9, 13, 1);
      _quarterRound(out, 10, 14, 2, 6);
      _quarterRound(out, 15, 3, 7, 11);
      _quarterRound(out, 0, 1, 2, 3);
      _quarterRound(out, 5, 6, 7, 4);
      _quarterRound(out, 10, 11, 8, 9);
      _quarterRound(out, 15, 12, 13, 14);
    }
    for (int i = 0; i < 16; i++) out[i] = (out[i] + inp[i]) & 0xFFFFFFFF;
  }

  static Uint8List _hsalsa20(Uint8List key, Uint8List nonce) {
    final inp = Uint32List(16);
    inp[0] = 0x61707865; inp[5] = 0x3320646e; inp[10] = 0x79622d32; inp[15] = 0x6b206574;
    final k = _bytesToU32(key);
    final n = _bytesToU32(nonce);
    inp[1] = k[0]; inp[2] = k[1]; inp[3] = k[2]; inp[4] = k[3];
    inp[11] = k[4]; inp[12] = k[5]; inp[13] = k[6]; inp[14] = k[7];
    inp[6] = n[0]; inp[7] = n[1]; inp[8] = n[2]; inp[9] = n[3];

    final x = Uint32List.fromList(inp);
    for (int i = 0; i < 10; i++) {
      _quarterRound(x, 0, 4, 8, 12);
      _quarterRound(x, 5, 9, 13, 1);
      _quarterRound(x, 10, 14, 2, 6);
      _quarterRound(x, 15, 3, 7, 11);
      _quarterRound(x, 0, 1, 2, 3);
      _quarterRound(x, 5, 6, 7, 4);
      _quarterRound(x, 10, 11, 8, 9);
      _quarterRound(x, 15, 12, 13, 14);
    }
    final out = Uint32List(8);
    out[0] = x[0]; out[1] = x[5]; out[2] = x[10]; out[3] = x[15];
    out[4] = x[6]; out[5] = x[7]; out[6] = x[8]; out[7] = x[9];
    return _u32ToBytes(out);
  }

  static bool _verifyPoly1305(Uint8List key, Uint8List ciphertext, Uint8List expectedMac) {
    final rBytes = Uint8List.fromList(key.sublist(0, 16));
    rBytes[3] &= 15; rBytes[7] &= 15; rBytes[11] &= 15; rBytes[15] &= 15;
    rBytes[4] &= 252; rBytes[8] &= 252; rBytes[12] &= 252;
    final r = _readLE(rBytes);
    final s = _readLE(key.sublist(16, 32));
    final p = (BigInt.one << 130) - BigInt.from(5);
    BigInt a = BigInt.zero;

    for (int i = 0; i < ciphertext.length; i += 16) {
      int end = i + 16;
      if (end > ciphertext.length) end = ciphertext.length;
      final block = Uint8List(17);
      block.setRange(0, end - i, ciphertext.sublist(i, end));
      block[end - i] = 1;
      a = (a + _readLE(block)) % p;
      a = (a * r) % p;
    }
    final mac = (a + s) & ((BigInt.one << 128) - BigInt.one);
    final macBytes = _writeLE(mac, 16);
    
    int diff = 0;
    for (int i = 0; i < 16; i++) {
      diff |= expectedMac[i] ^ macBytes[i];
    }
    return diff == 0;
  }

  static BigInt _readLE(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  static Uint8List _writeLE(BigInt value, int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = (value & BigInt.from(0xFF)).toInt();
      value >>= 8;
    }
    return bytes;
  }

  static Uint32List _bytesToU32(Uint8List bytes) {
    final res = Uint32List(bytes.length ~/ 4);
    for (int i = 0; i < bytes.length; i += 4) {
      res[i ~/ 4] = bytes[i] | (bytes[i+1] << 8) | (bytes[i+2] << 16) | (bytes[i+3] << 24);
    }
    return res;
  }

  static Uint8List _u32ToBytes(Uint32List u32) {
    final bytes = Uint8List(u32.length * 4);
    for (int i = 0; i < u32.length; i++) {
      final v = u32[i];
      bytes[i * 4] = v & 0xFF;
      bytes[i * 4 + 1] = (v >> 8) & 0xFF;
      bytes[i * 4 + 2] = (v >> 16) & 0xFF;
      bytes[i * 4 + 3] = (v >> 24) & 0xFF;
    }
    return bytes;
  }
}
