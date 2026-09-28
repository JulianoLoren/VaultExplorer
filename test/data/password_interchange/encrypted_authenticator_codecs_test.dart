// Exercises the *wiring* of the encrypted-backup codecs -- header parsing,
// byte offsets, the KDF parameters handed to the native layer, wrong-
// password handling -- against a fake VaultCryptoApi. The real primitives
// (scrypt, PBKDF2, AES-GCM) live in the C++ engine and are covered there;
// what can go wrong on the Dart side is slicing the wrong bytes or passing
// the wrong cost parameters, which is exactly what these pin down.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/data/services/password_interchange/aegis_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/andotp_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/twofas_json_codec.dart';

const _secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

class _Kdf {
  final String kind;
  final Uint8List password;
  final Uint8List salt;
  final Map<String, Object?> params;
  _Kdf(this.kind, this.password, this.salt, this.params);
}

class _Gcm {
  final Uint8List key;
  final Uint8List iv;
  final Uint8List ciphertextAndTag;
  final Uint8List? aad;
  _Gcm(this.key, this.iv, this.ciphertextAndTag, [this.aad]);
}

/// Records every call and answers from scripts: [derivedKey] for the KDFs
/// and [plaintexts] (consumed in order) for AES-GCM. A null entry means "the
/// tag didn't verify" -- what the native side reports for a wrong password.
class _FakeCrypto extends VaultCryptoApi {
  _FakeCrypto({required this.derivedKey, required this.plaintexts})
      : super(const MethodChannel('test/unused'));

  final Uint8List derivedKey;
  final List<Uint8List?> plaintexts;
  final kdfs = <_Kdf>[];
  final gcms = <_Gcm>[];

  @override
  Future<Uint8List?> pbkdf2({
    required Uint8List password,
    required Uint8List salt,
    required int iterations,
    required int outputLen,
    required Pbkdf2Hash hash,
  }) async {
    kdfs.add(_Kdf('pbkdf2', Uint8List.fromList(password), salt, {
      'iterations': iterations,
      'outputLen': outputLen,
      'hash': hash,
    }));
    return Uint8List.fromList(derivedKey);
  }

  @override
  Future<Uint8List?> scrypt({
    required Uint8List password,
    required Uint8List salt,
    required int n,
    required int r,
    required int p,
    required int dkLen,
  }) async {
    kdfs.add(_Kdf('scrypt', Uint8List.fromList(password), salt, {'n': n, 'r': r, 'p': p, 'dkLen': dkLen}));
    return Uint8List.fromList(derivedKey);
  }

  @override
  Future<Uint8List?> aesGcmDecrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertextAndTag,
    Uint8List? aad,
  }) async {
    gcms.add(_Gcm(Uint8List.fromList(key), iv, ciphertextAndTag, aad));
    // A copy: the codec zeroizes key material it's handed once it's done.
    final next = plaintexts.removeAt(0);
    return next == null ? null : Uint8List.fromList(next);
  }

  @override
  Future<Uint8List?> aesCbcDecrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) async {
    final next = plaintexts.removeAt(0);
    return next == null ? null : Uint8List.fromList(next);
  }

  @override
  Future<Uint8List?> xchacha20Poly1305Open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertextAndTag,
    Uint8List? aad,
  }) async {
    final next = plaintexts.removeAt(0);
    return next == null ? null : Uint8List.fromList(next);
  }

  @override
  Future<Uint8List?> argon2id({
    required Uint8List password,
    required Uint8List salt,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
    required int outputLen,
  }) async {
    return Uint8List.fromList(derivedKey);
  }
}

Uint8List _u8(List<int> v) => Uint8List.fromList(v);
String _hex(List<int> v) => v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('andOTP encrypted backup', () {
    final salt = _u8(List.generate(12, (i) => 0x10 + i));
    final iv = _u8(List.generate(12, (i) => 0x40 + i));
    final ciphertextAndTag = _u8(List.generate(40, (i) => 0x80 + i));

    Uint8List backup({int iterations = 150000}) {
      final header = ByteData(4)..setUint32(0, iterations, Endian.big);
      return _u8([...header.buffer.asUint8List(), ...salt, ...iv, ...ciphertextAndTag]);
    }

    final json = jsonEncode([
      {'secret': _secret, 'issuer': 'Example', 'label': 'alice', 'digits': 6, 'type': 'TOTP', 'algorithm': 'SHA1', 'period': 30},
    ]);

    test('slices the header correctly and derives with PBKDF2-HMAC-SHA1', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 7)), plaintexts: [_bytes(json)]);
      final result = await AndOtpJsonCodec(crypto: fake).decode(backup(), password: 'pässword 🔑');

      expect(result.records.single.title, 'Example (alice)');

      final kdf = fake.kdfs.single;
      expect(kdf.kind, 'pbkdf2');
      expect(kdf.params['hash'], Pbkdf2Hash.sha1);
      expect(kdf.params['iterations'], 150000);
      expect(kdf.params['outputLen'], 32);
      expect(kdf.salt, salt);
      // Standard UTF-8, emoji included -- not JNI's modified UTF-8.
      expect(kdf.password, utf8.encode('pässword 🔑'));

      final gcm = fake.gcms.single;
      expect(gcm.iv, iv);
      expect(gcm.ciphertextAndTag, ciphertextAndTag);
      expect(gcm.key, List.filled(32, 7));
    });

    test('a failed tag is reported as an incorrect password', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 7)), plaintexts: [null]);
      await expectLater(
        AndOtpJsonCodec(crypto: fake).decode(backup(), password: 'wrong'),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
    });

    test('a missing password asks for one without running any crypto', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 7)), plaintexts: []);
      await expectLater(
        AndOtpJsonCodec(crypto: fake).decode(backup()),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
      expect(fake.kdfs, isEmpty);
    });

    test('refuses an absurd iteration count instead of grinding on it', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 7)), plaintexts: [_bytes(json)]);
      await expectLater(
        AndOtpJsonCodec(crypto: fake).decode(backup(iterations: 0xFFFFFFFF), password: 'x'),
        throwsA(isA<PasswordFileFormatException>()),
      );
      expect(fake.kdfs, isEmpty);
    });

    test('a truncated file is a format error, not a crash', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 7)), plaintexts: []);
      // Non-UTF-8 (so treated as encrypted) but shorter than the header.
      await expectLater(
        AndOtpJsonCodec(crypto: fake).decode(_u8(List.filled(20, 0xFF)), password: 'x'),
        throwsA(isA<PasswordFileFormatException>()),
      );
    });
  });

  group('2FAS encrypted backup', () {
    final ciphertextAndTag = _u8(List.generate(48, (i) => 0x20 + i));
    final salt = _u8(List.generate(256, (i) => i));
    final iv = _u8(List.generate(12, (i) => 0x60 + i));

    final servicesJson = jsonEncode([
      {
        'name': 'Example', 'secret': _secret,
        'otp': {'account': 'alice', 'issuer': 'Example', 'digits': 6, 'period': 30, 'algorithm': 'SHA1', 'tokenType': 'TOTP'},
      },
    ]);

    Uint8List backup() => _bytes(jsonEncode({
          'schemaVersion': 4,
          'services': <Object?>[],
          'servicesEncrypted':
              '${base64Encode(ciphertextAndTag)}:${base64Encode(salt)}:${base64Encode(iv)}',
          'reference': 'x',
        }));

    test('splits the three parts and derives with PBKDF2-HMAC-SHA256 x 10000', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 9)), plaintexts: [_bytes(servicesJson)]);
      final result = await TwoFasJsonCodec(crypto: fake).decode(backup(), password: 'secret');

      expect(result.records.single.fields['totp_secret'], _secret);

      final kdf = fake.kdfs.single;
      expect(kdf.params['hash'], Pbkdf2Hash.sha256);
      expect(kdf.params['iterations'], 10000);
      expect(kdf.params['outputLen'], 32);
      expect(kdf.salt, salt);

      final gcm = fake.gcms.single;
      expect(gcm.iv, iv);
      expect(gcm.ciphertextAndTag, ciphertextAndTag);
    });

    test('wrong password / no password', () async {
      final wrong = _FakeCrypto(derivedKey: _u8(List.filled(32, 9)), plaintexts: [null]);
      await expectLater(
        TwoFasJsonCodec(crypto: wrong).decode(backup(), password: 'nope'),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
      final none = _FakeCrypto(derivedKey: _u8(List.filled(32, 9)), plaintexts: []);
      await expectLater(
        TwoFasJsonCodec(crypto: none).decode(backup()),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
      expect(none.kdfs, isEmpty);
    });
  });

  group('Aegis encrypted vault', () {
    final slotSalt = _u8(List.generate(32, (i) => i));
    final slotKey = _u8(List.generate(32, (i) => 0x30 + i));
    final slotNonce = _u8(List.generate(12, (i) => 0x50 + i));
    final slotTag = _u8(List.generate(16, (i) => 0x70 + i));
    final dbNonce = _u8(List.generate(12, (i) => 0x90 + i));
    final dbTag = _u8(List.generate(16, (i) => 0xB0 + i));
    final dbCipher = _u8(List.generate(64, (i) => 0xC0 + (i % 32)));
    final masterKey = _u8(List.generate(32, (i) => 0xE0 + (i % 16)));

    final vaultJson = jsonEncode({
      'version': 2,
      'entries': [
        {
          'type': 'totp', 'name': 'alice', 'issuer': 'Example',
          'info': {'secret': _secret, 'algo': 'SHA1', 'digits': 6, 'period': 30},
        },
      ],
      'groups': <Object?>[],
    });

    Uint8List vault({List<Map<String, Object?>>? extraSlots}) => _bytes(jsonEncode({
          'version': 1,
          'header': {
            'slots': [
              // A biometric slot first: it must be ignored, not tried.
              {'type': 2, 'uuid': 'bio', 'key': 'aa', 'key_params': {'nonce': '00', 'tag': '00'}},
              {
                'type': 1, 'uuid': 'pw', 'key': _hex(slotKey), 'key_params': {'nonce': _hex(slotNonce), 'tag': _hex(slotTag)},
                'n': 32768, 'r': 8, 'p': 1, 'salt': _hex(slotSalt), 'repaired': true,
              },
              ...?extraSlots,
            ],
            'params': {'nonce': _hex(dbNonce), 'tag': _hex(dbTag)},
          },
          'db': base64Encode(dbCipher),
        }));

    test('unwraps the master key with scrypt, then decrypts the vault', () async {
      final fake = _FakeCrypto(
        derivedKey: _u8(List.filled(32, 5)),
        plaintexts: [masterKey, _bytes(vaultJson)],
      );
      final result = await AegisJsonCodec(crypto: fake).decode(vault(), password: 'hunter2');
      expect(result.records.single.title, 'Example (alice)');

      final kdf = fake.kdfs.single;
      expect(kdf.kind, 'scrypt');
      expect(kdf.params, {'n': 32768, 'r': 8, 'p': 1, 'dkLen': 32});
      expect(kdf.salt, slotSalt);
      expect(kdf.password, utf8.encode('hunter2'));

      expect(fake.gcms, hasLength(2));
      // 1) slot: key = scrypt output, ct = wrapped key || slot tag.
      expect(fake.gcms[0].key, List.filled(32, 5));
      expect(fake.gcms[0].iv, slotNonce);
      expect(fake.gcms[0].ciphertextAndTag, [...slotKey, ...slotTag]);
      // 2) db: key = the unwrapped master key, ct = db bytes || params tag.
      expect(fake.gcms[1].key, masterKey);
      expect(fake.gcms[1].iv, dbNonce);
      expect(fake.gcms[1].ciphertextAndTag, [...dbCipher, ...dbTag]);
    });

    test('a slot that fails to open means an incorrect password', () async {
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 5)), plaintexts: [null]);
      await expectLater(
        AegisJsonCodec(crypto: fake).decode(vault(), password: 'wrong'),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
    });

    test('with two password slots, falls through to the second', () async {
      final second = {
        'type': 1, 'uuid': 'pw2', 'key': _hex(slotKey), 'key_params': {'nonce': _hex(slotNonce), 'tag': _hex(slotTag)},
        'n': 16384, 'r': 8, 'p': 1, 'salt': _hex(slotSalt),
      };
      final fake = _FakeCrypto(
        derivedKey: _u8(List.filled(32, 5)),
        plaintexts: [null, masterKey, _bytes(vaultJson)],
      );
      final result = await AegisJsonCodec(crypto: fake).decode(vault(extraSlots: [second]), password: 'hunter2');
      expect(result.records, hasLength(1));
      expect(fake.kdfs, hasLength(2));
      expect(fake.kdfs[1].params['n'], 16384);
    });

    test('an absurd scrypt cost is refused before any key derivation', () async {
      final hostile = _bytes(jsonEncode({
        'version': 1,
        'header': {
          'slots': [
            {
              'type': 1, 'key': _hex(slotKey), 'key_params': {'nonce': _hex(slotNonce), 'tag': _hex(slotTag)},
              'n': 1 << 30, 'r': 8, 'p': 1, 'salt': _hex(slotSalt),
            },
          ],
          'params': {'nonce': _hex(dbNonce), 'tag': _hex(dbTag)},
        },
        'db': base64Encode(dbCipher),
      }));
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 5)), plaintexts: []);
      await expectLater(
        AegisJsonCodec(crypto: fake).decode(hostile, password: 'x'),
        throwsA(isA<PasswordFileFormatException>()),
      );
      expect(fake.kdfs, isEmpty);
    });

    test('a vault with only a biometric slot cannot be opened here', () async {
      final bioOnly = _bytes(jsonEncode({
        'version': 1,
        'header': {
          'slots': [
            {'type': 2, 'key': 'aa', 'key_params': {'nonce': '00', 'tag': '00'}},
          ],
          'params': {'nonce': _hex(dbNonce), 'tag': _hex(dbTag)},
        },
        'db': base64Encode(dbCipher),
      }));
      final fake = _FakeCrypto(derivedKey: _u8(List.filled(32, 5)), plaintexts: []);
      await expectLater(
        AegisJsonCodec(crypto: fake).decode(bioOnly, password: 'x'),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
      expect(fake.kdfs, isEmpty);
    });
  });
}
