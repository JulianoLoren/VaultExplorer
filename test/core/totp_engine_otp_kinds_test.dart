import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/core/utils/totp_engine.dart';

import '../helpers/reference_hmac_crypto.dart';

// RFC 4226 / RFC 6238 test secret: ASCII "12345678901234567890".
const _rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

// HMAC comes from the native layer in the app; here a reference
// implementation stands in, so these tests pin the engine's own logic (base32,
// counters, truncation, Steam's alphabet) against the published vectors.
final _crypto = ReferenceHmacCrypto();

Future<String> _code(TotpConfig config, {DateTime? at}) =>
    TotpEngine.generateCode(config, crypto: _crypto, at: at);

Future<String> _nextCode(TotpConfig config, {DateTime? at}) =>
    TotpEngine.generateNextCode(config, crypto: _crypto, at: at);

void main() {
  group('HOTP (RFC 4226 Appendix D)', () {
    const expected = [
      '755224', '287082', '359152', '969429', '338314',
      '254676', '287922', '162583', '399871', '520489',
    ];

    test('generates the published test vectors for counters 0-9', () async {
      for (var counter = 0; counter < expected.length; counter++) {
        final config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: counter);
        expect(await _code(config), expected[counter], reason: 'counter $counter');
      }
    });

    test('ignores the clock', () async {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: 3);
      final a = await _code(config, at: DateTime.utc(2020));
      final b = await _code(config, at: DateTime.utc(2030));
      expect(a, b);
    });

    test('generateNextCode is the code for counter + 1', () async {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: 4);
      expect(await _nextCode(config), '254676');
    });

    test('fromFields reads totp_type and hotp_counter', () async {
      final config = TotpConfig.fromFields({
        'totp_secret': _rfcSecret,
        'totp_type': 'hotp',
        'hotp_counter': '2',
      });
      expect(config.kind, OtpKind.hotp);
      expect(config.isTimeBased, isFalse);
      expect(await _code(config), '359152');
    });

    test('fromFields reads the kind and counter out of a full otpauth URI', () async {
      final config = TotpConfig.fromFields({
        'totp_secret': 'otpauth://hotp/Example:alice?secret=$_rfcSecret&counter=1',
      });
      expect(config.kind, OtpKind.hotp);
      expect(config.counter, 1);
      expect(await _code(config), '287082');
    });

    test('an explicit hotp_counter field wins over the URI counter', () async {
      final config = TotpConfig.fromFields({
        'totp_secret': 'otpauth://hotp/x?secret=$_rfcSecret&counter=1',
        'hotp_counter': '0',
      });
      expect(await _code(config), '755224');
    });
  });

  group('TOTP regression (RFC 6238)', () {
    test('SHA1, 8 digits at T=59 is 94287082', () async {
      const config = TotpConfig(secret: _rfcSecret, digits: 8);
      final at = DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true);
      expect(await _code(config, at: at), '94287082');
    });

    test('a plain item with no totp_type is time-based', () {
      final config = TotpConfig.fromFields({'totp_secret': _rfcSecret});
      expect(config.kind, OtpKind.totp);
      expect(config.isTimeBased, isTrue);
    });
  });

  group('Steam Guard', () {
    const alphabet = '23456789BCDFGHJKMNPQRTVWXY';

    test('codes are five characters from the Steam alphabet', () async {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.steam);
      for (var minute = 0; minute < 50; minute++) {
        final code = await _code(
          config,
          at: DateTime.utc(2024, 1, 1, 0, minute),
        );
        expect(code.length, 5);
        expect(code.split('').every(alphabet.contains), isTrue, reason: code);
      }
    });

    test('is stable within a 30 second step and changes across steps', () async {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.steam);
      final a = await _code(config, at: DateTime.utc(2024, 1, 1, 0, 0, 1));
      final b = await _code(config, at: DateTime.utc(2024, 1, 1, 0, 0, 29));
      final c = await _code(config, at: DateTime.utc(2024, 1, 1, 0, 0, 31));
      expect(a, b);
      expect(a == c, isFalse);
    });

    test('fromFields pins Steam entries to SHA1 / 5 characters / 30 seconds', () {
      final config = TotpConfig.fromFields({
        'totp_secret': _rfcSecret,
        'totp_type': 'steam',
        'totp_algorithm': 'SHA512',
        'totp_digits': '8',
        'totp_period': '60',
      });
      expect(config.kind, OtpKind.steam);
      expect(config.algorithm, TotpAlgorithm.sha1);
      expect(config.digits, 5);
      expect(config.period, 30);
    });

    test('formatOtpCode leaves a Steam code ungrouped', () {
      expect(formatOtpCode('AB3D5', OtpKind.steam), 'AB3D5');
      expect(formatOtpCode('123456', OtpKind.totp), '123 456');
    });
  });

  group('TOTP algorithms (RFC 6238 Appendix B)', () {
    // ASCII "12345678901234567890" repeated/extended to the key length each
    // hash uses in the RFC: 32 bytes for SHA-256, 64 bytes for SHA-512.
    const secretSha256 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA';
    const secretSha512 =
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA';
    DateTime utc(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

    test('SHA256, 8 digits', () async {
      const config = TotpConfig(secret: secretSha256, algorithm: TotpAlgorithm.sha256, digits: 8);
      expect(await _code(config, at: utc(59)), '46119246');
      expect(await _code(config, at: utc(1111111109)), '68084774');
      expect(await _code(config, at: utc(20000000000)), '77737706');
    });

    test('SHA512, 8 digits', () async {
      const config = TotpConfig(secret: secretSha512, algorithm: TotpAlgorithm.sha512, digits: 8);
      expect(await _code(config, at: utc(59)), '90693936');
      expect(await _code(config, at: utc(1111111109)), '25091201');
      expect(await _code(config, at: utc(20000000000)), '47863826');
    });

    test('each algorithm reaches the native layer as its own HMAC hash', () async {
      const expected = {
        TotpAlgorithm.sha1: HmacHash.sha1,
        TotpAlgorithm.sha256: HmacHash.sha256,
        TotpAlgorithm.sha512: HmacHash.sha512,
      };
      for (final entry in expected.entries) {
        _crypto.hmacCalls.clear();
        await _code(TotpConfig(secret: _rfcSecret, algorithm: entry.key), at: utc(59));
        expect(_crypto.hmacCalls.single.hash, entry.value, reason: entry.key.name);
      }
    });

    test('Steam is HMAC-SHA1 whatever algorithm the config carries', () async {
      _crypto.hmacCalls.clear();
      await _code(
        const TotpConfig(secret: _rfcSecret, kind: OtpKind.steam, algorithm: TotpAlgorithm.sha512),
        at: utc(59),
      );
      expect(_crypto.hmacCalls.single.hash, HmacHash.sha1);
    });
  });

  group('stepFor', () {
    DateTime utc(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

    test('is the time step for TOTP and Steam', () {
      const totp = TotpConfig(secret: _rfcSecret);
      expect(TotpEngine.stepFor(totp, at: utc(29)), 0);
      expect(TotpEngine.stepFor(totp, at: utc(30)), 1);
      expect(TotpEngine.stepFor(totp, at: utc(59)), 1);
      expect(TotpEngine.stepFor(totp, at: utc(60)), 2);

      const longPeriod = TotpConfig(secret: _rfcSecret, period: 60);
      expect(TotpEngine.stepFor(longPeriod, at: utc(119)), 1);

      const steam = TotpConfig(secret: _rfcSecret, kind: OtpKind.steam);
      expect(TotpEngine.stepFor(steam, at: utc(61)), 2);
    });

    test('is the counter for HOTP and ignores the clock', () {
      const hotp = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: 7);
      expect(TotpEngine.stepFor(hotp, at: utc(0)), 7);
      expect(TotpEngine.stepFor(hotp, at: utc(999999)), 7);
    });
  });

  group('base32Encode', () {
    test('matches the RFC 4648 vector for "foobar" (unpadded)', () {
      final bytes = Uint8List.fromList('foobar'.codeUnits);
      expect(base32Encode(bytes), 'MZXW6YTBOI');
    });

    test('round-trips with base32Decode', () {
      expect(base32Encode(base32Decode(_rfcSecret)), _rfcSecret);
    });
  });
}
