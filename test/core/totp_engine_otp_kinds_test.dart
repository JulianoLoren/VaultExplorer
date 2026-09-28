import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/utils/totp_engine.dart';

// RFC 4226 / RFC 6238 test secret: ASCII "12345678901234567890".
const _rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

void main() {
  group('HOTP (RFC 4226 Appendix D)', () {
    const expected = [
      '755224', '287082', '359152', '969429', '338314',
      '254676', '287922', '162583', '399871', '520489',
    ];

    test('generates the published test vectors for counters 0-9', () {
      for (var counter = 0; counter < expected.length; counter++) {
        final config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: counter);
        expect(TotpEngine.generateCode(config), expected[counter], reason: 'counter $counter');
      }
    });

    test('ignores the clock', () {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: 3);
      final a = TotpEngine.generateCode(config, at: DateTime.utc(2020));
      final b = TotpEngine.generateCode(config, at: DateTime.utc(2030));
      expect(a, b);
    });

    test('generateNextCode is the code for counter + 1', () {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.hotp, counter: 4);
      expect(TotpEngine.generateNextCode(config), '254676');
    });

    test('fromFields reads totp_type and hotp_counter', () {
      final config = TotpConfig.fromFields({
        'totp_secret': _rfcSecret,
        'totp_type': 'hotp',
        'hotp_counter': '2',
      });
      expect(config.kind, OtpKind.hotp);
      expect(config.isTimeBased, isFalse);
      expect(TotpEngine.generateCode(config), '359152');
    });

    test('fromFields reads the kind and counter out of a full otpauth URI', () {
      final config = TotpConfig.fromFields({
        'totp_secret': 'otpauth://hotp/Example:alice?secret=$_rfcSecret&counter=1',
      });
      expect(config.kind, OtpKind.hotp);
      expect(config.counter, 1);
      expect(TotpEngine.generateCode(config), '287082');
    });

    test('an explicit hotp_counter field wins over the URI counter', () {
      final config = TotpConfig.fromFields({
        'totp_secret': 'otpauth://hotp/x?secret=$_rfcSecret&counter=1',
        'hotp_counter': '0',
      });
      expect(TotpEngine.generateCode(config), '755224');
    });
  });

  group('TOTP regression (RFC 6238)', () {
    test('SHA1, 8 digits at T=59 is 94287082', () {
      const config = TotpConfig(secret: _rfcSecret, digits: 8);
      final at = DateTime.fromMillisecondsSinceEpoch(59 * 1000, isUtc: true);
      expect(TotpEngine.generateCode(config, at: at), '94287082');
    });

    test('a plain item with no totp_type is time-based', () {
      final config = TotpConfig.fromFields({'totp_secret': _rfcSecret});
      expect(config.kind, OtpKind.totp);
      expect(config.isTimeBased, isTrue);
    });
  });

  group('Steam Guard', () {
    const alphabet = '23456789BCDFGHJKMNPQRTVWXY';

    test('codes are five characters from the Steam alphabet', () {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.steam);
      for (var minute = 0; minute < 50; minute++) {
        final code = TotpEngine.generateCode(
          config,
          at: DateTime.utc(2024, 1, 1, 0, minute),
        );
        expect(code.length, 5);
        expect(code.split('').every(alphabet.contains), isTrue, reason: code);
      }
    });

    test('is stable within a 30 second step and changes across steps', () {
      const config = TotpConfig(secret: _rfcSecret, kind: OtpKind.steam);
      final a = TotpEngine.generateCode(config, at: DateTime.utc(2024, 1, 1, 0, 0, 1));
      final b = TotpEngine.generateCode(config, at: DateTime.utc(2024, 1, 1, 0, 0, 29));
      final c = TotpEngine.generateCode(config, at: DateTime.utc(2024, 1, 1, 0, 0, 31));
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
