// Exercises the *wiring* of Bitwarden's password-protected export decryption
// after its HMAC moved to the native layer: the HKDF-Expand subkeys (SHA-256,
// info "enc"/"mac" + 0x01), and the MAC check that decides "right password".
//
// PBKDF2 and AES-CBC are scripted fakes (the real primitives live in the
// native engine); the MACs in the fixture are computed here, independently of
// the codec, from the master key, so a wrong info string, hash or byte layout
// on the codec's side makes the MAC check fail.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/data/services/password_interchange/bitwarden_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

import '../../helpers/reference_hmac_crypto.dart';

class _FakeBitwardenCrypto extends ReferenceHmacCrypto {
  _FakeBitwardenCrypto({required this.masterKey, required this.cbcPlaintexts});

  final Uint8List masterKey;

  /// Consumed in order: the unwrapped 64-byte symmetric key, then the payload.
  final List<Uint8List> cbcPlaintexts;

  Pbkdf2Hash? pbkdf2Hash;

  @override
  Future<Uint8List?> pbkdf2({
    required Uint8List password,
    required Uint8List salt,
    required int iterations,
    required int outputLen,
    required Pbkdf2Hash hash,
  }) async {
    pbkdf2Hash = hash;
    // A copy: the codec zeroizes key material it's handed once it's done.
    return Uint8List.fromList(masterKey);
  }

  @override
  Future<Uint8List?> aesCbcDecrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) async {
    return Uint8List.fromList(cbcPlaintexts.removeAt(0));
  }
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

String _cipherString(Uint8List iv, Uint8List ct, Uint8List mac) =>
    '2.${base64.encode(iv)}|${base64.encode(ct)}|${base64.encode(mac)}';

void main() {
  final masterKey = Uint8List.fromList(List.generate(32, (i) => i));
  final symKey = Uint8List.fromList(List.generate(64, (i) => 100 + i));
  final payload = utf8.encode(jsonEncode({
    'encrypted': false,
    'folders': <Object>[],
    'items': [
      {
        'type': 1,
        'name': 'Example',
        'login': {'username': 'alice', 'password': 'hunter2'},
      },
    ],
  }));

  Future<(_FakeBitwardenCrypto, Uint8List)> buildExport({bool tamperValidationMac = false}) async {
    final crypto = _FakeBitwardenCrypto(
      masterKey: masterKey,
      cbcPlaintexts: [symKey, Uint8List.fromList(payload)],
    );

    // What Bitwarden derives from the master key, computed independently of
    // the codec: stretched MAC key = HMAC-SHA256(master, "mac" | 0x01).
    final stretchedMacKey = (await crypto.hmac(
      key: masterKey,
      data: Uint8List.fromList([...utf8.encode('mac'), 1]),
      hash: HmacHash.sha256,
    ))!;

    final valIv = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final valCt = Uint8List.fromList(List.generate(64, (i) => 255 - i));
    final valMac = (await crypto.hmac(
      key: stretchedMacKey,
      data: Uint8List.fromList([...valIv, ...valCt]),
      hash: HmacHash.sha256,
    ))!;
    if (tamperValidationMac) valMac[0] ^= 0xff;

    // The payload is authenticated with the second half of the unwrapped key.
    final dataIv = Uint8List.fromList(List.generate(16, (i) => 50 + i));
    final dataCt = Uint8List.fromList(List.generate(48, (i) => 7 * i % 251));
    final dataMac = (await crypto.hmac(
      key: Uint8List.fromList(symKey.sublist(32, 64)),
      data: Uint8List.fromList([...dataIv, ...dataCt]),
      hash: HmacHash.sha256,
    ))!;

    crypto.hmacCalls.clear();
    final root = {
      'encrypted': true,
      'passwordProtected': true,
      'salt': 'alice@example.com',
      'kdfType': 0,
      'kdfIterations': 100000,
      'encKeyValidation_DO_NOT_EDIT': _cipherString(valIv, valCt, valMac),
      'data': _cipherString(dataIv, dataCt, dataMac),
    };
    return (crypto, Uint8List.fromList(utf8.encode(jsonEncode(root))));
  }

  test('decrypts a password-protected export, deriving HKDF subkeys with SHA-256', () async {
    final (crypto, file) = await buildExport();

    final decoded = await BitwardenJsonCodec(crypto: crypto).decode(file, password: 'hunter2');

    expect(decoded.records, hasLength(1));
    expect(crypto.pbkdf2Hash, Pbkdf2Hash.sha256);
    expect(crypto.hmacCalls.every((c) => c.hash == HmacHash.sha256), isTrue);

    final encInfo = [...utf8.encode('enc'), 1];
    final macInfo = [...utf8.encode('mac'), 1];
    expect(
      crypto.hmacCalls.where((c) => _same(c.key, masterKey) && _same(c.data, encInfo)),
      hasLength(1),
      reason: 'HKDF-Expand("enc") over the master key',
    );
    expect(
      crypto.hmacCalls.where((c) => _same(c.key, masterKey) && _same(c.data, macInfo)),
      hasLength(1),
      reason: 'HKDF-Expand("mac") over the master key',
    );
  });

  test('a validation MAC that does not verify is reported as a wrong password', () async {
    final (crypto, file) = await buildExport(tamperValidationMac: true);

    await expectLater(
      BitwardenJsonCodec(crypto: crypto).decode(file, password: 'hunter2'),
      throwsA(isA<PasswordFileIncorrectPasswordException>()),
    );
  });
}
