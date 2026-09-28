import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/aegis_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/andotp_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/google_auth_migration_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/lastpass_authenticator_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/otpauth_uri_list_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_registry.dart';
import 'package:vaultexplorer/data/services/password_interchange/raivo_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/twofas_json_codec.dart';

// ASCII "12345678901234567890" -- the RFC 4226 test secret.
const _secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('otpauth:// URI list', () {
    const codec = OtpAuthUriListCodec();

    test('reads totp, hotp and steam URIs', () async {
      final text = [
        'otpauth://totp/Example:alice@example.com?secret=$_secret&issuer=Example&digits=8&period=60&algorithm=SHA256',
        'otpauth://hotp/Bank:bob?secret=$_secret&issuer=Bank&counter=7',
        'otpauth://steam/Steam:carol?secret=$_secret&issuer=Steam',
      ].join('\n');
      final result = await codec.decode(_bytes(text));
      expect(result.records, hasLength(3));

      final totp = result.records[0];
      expect(totp.type, VaultItemType.authenticator);
      expect(totp.title, 'Example (alice@example.com)');
      expect(totp.fields['totp_algorithm'], 'SHA256');
      expect(totp.fields['totp_digits'], '8');
      expect(totp.fields['totp_period'], '60');
      expect(totp.fields.containsKey('totp_type'), isFalse);

      final hotp = result.records[1];
      expect(hotp.fields['totp_type'], 'hotp');
      expect(hotp.fields['hotp_counter'], '7');

      final steam = result.records[2];
      expect(steam.fields['totp_type'], 'steam');
      expect(steam.fields['totp_digits'], '5');
    });

    test('skips an unsupported algorithm with a warning and keeps the rest', () async {
      final text = 'otpauth://totp/A?secret=$_secret&algorithm=MD5\n'
          'otpauth://totp/B?secret=$_secret';
      final result = await codec.decode(_bytes(text));
      expect(result.records, hasLength(1));
      expect(result.warnings, hasLength(1));
    });

    test('accepts several comma-separated URIs on one line', () async {
      final text = 'otpauth://totp/A?secret=$_secret, otpauth://totp/B?secret=$_secret';
      final result = await codec.decode(_bytes(text));
      expect(result.records, hasLength(2));
    });

    test('throws when nothing usable is in the file', () {
      expect(
        () => codec.decode(_bytes('hello world')),
        throwsA(isA<PasswordFileFormatException>()),
      );
    });

    test('export round-trips through import', () async {
      final imported = await codec.decode(_bytes(
        'otpauth://hotp/Bank:bob?secret=$_secret&issuer=Bank&counter=7&digits=8\n'
        'otpauth://totp/Example:alice?secret=$_secret&issuer=Example&period=60',
      ));
      final exported = await codec.encode(imported.records);
      final again = await codec.decode(exported);
      expect(again.records, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(again.records[i].fields, imported.records[i].fields);
      }
    });
  });

  group('Google Authenticator transfer code', () {
    const codec = GoogleAuthMigrationCodec();

    // Hand-built protobuf: MigrationPayload { otp_parameters { ... } }.
    Uint8List param({
      required List<int> secret,
      required String name,
      required String issuer,
      int algorithm = 1,
      int digits = 1,
      int type = 2,
      int? counter,
    }) {
      final inner = <int>[
        0x0A, secret.length, ...secret,
        0x12, name.length, ...utf8.encode(name),
        0x1A, issuer.length, ...utf8.encode(issuer),
        0x20, algorithm,
        0x28, digits,
        0x30, type,
        if (counter != null) ...[0x38, counter],
      ];
      return Uint8List.fromList([0x0A, inner.length, ...inner]);
    }

    String uriFor(List<Uint8List> params) {
      final payload = Uint8List.fromList([for (final p in params) ...p]);
      return 'otpauth-migration://offline?data=${Uri.encodeComponent(base64Encode(payload))}';
    }

    test('reads a TOTP entry and splits "Issuer:account"', () async {
      final uri = uriFor([
        param(secret: '12345678901234567890'.codeUnits, name: 'Example:alice@example.com', issuer: 'Example'),
      ]);
      final result = await codec.decode(_bytes(uri));
      expect(result.records, hasLength(1));
      final r = result.records.single;
      expect(r.title, 'Example (alice@example.com)');
      expect(r.fields['issuer'], 'Example');
      expect(r.fields['account'], 'alice@example.com');
      expect(r.fields['totp_secret'], _secret);
      expect(r.fields['totp_digits'], '6');
    });

    test('reads an HOTP entry with its counter, and 8-digit SHA256', () async {
      final uri = uriFor([
        param(
          secret: '12345678901234567890'.codeUnits,
          name: 'bob',
          issuer: 'Bank',
          algorithm: 2,
          digits: 2,
          type: 1,
          counter: 5,
        ),
      ]);
      final r = (await codec.decode(_bytes(uri))).records.single;
      expect(r.fields['totp_type'], 'hotp');
      expect(r.fields['hotp_counter'], '5');
      expect(r.fields['totp_algorithm'], 'SHA256');
      expect(r.fields['totp_digits'], '8');
    });

    test('skips MD5 with a warning', () async {
      final uri = uriFor([
        param(secret: '12345678901234567890'.codeUnits, name: 'a', issuer: 'MD5', algorithm: 4),
        param(secret: '12345678901234567890'.codeUnits, name: 'b', issuer: 'OK'),
      ]);
      final result = await codec.decode(_bytes(uri));
      expect(result.records, hasLength(1));
      expect(result.warnings, hasLength(1));
    });

    test('several URIs (a split export) are combined', () async {
      final a = uriFor([param(secret: '12345678901234567890'.codeUnits, name: 'a', issuer: 'A')]);
      final b = uriFor([param(secret: '12345678901234567890'.codeUnits, name: 'b', issuer: 'B')]);
      final result = await codec.decode(_bytes('$a\n$b'));
      expect(result.records, hasLength(2));
    });
  });

  group('Aegis', () {
    const codec = AegisJsonCodec();

    final plain = jsonEncode({
      'version': 1,
      'header': {'slots': null, 'params': null},
      'db': {
        'version': 2,
        'entries': [
          {
            'type': 'totp', 'uuid': '1', 'name': 'alice', 'issuer': 'Example', 'note': 'n',
            'favorite': true, 'groups': ['g1'],
            'info': {'secret': _secret, 'algo': 'SHA1', 'digits': 6, 'period': 30},
          },
          {
            'type': 'hotp', 'name': 'bob', 'issuer': 'Bank',
            'info': {'secret': _secret, 'algo': 'SHA256', 'digits': 8, 'counter': 7},
          },
          {
            'type': 'steam', 'name': 'carol', 'issuer': 'Steam',
            'info': {'secret': _secret, 'algo': 'SHA1', 'digits': 5, 'period': 30},
          },
          {
            'type': 'yandex', 'name': 'dave', 'issuer': 'Y',
            'info': {'secret': 'X', 'algo': 'SHA256', 'digits': 16},
          },
        ],
        'groups': [
          {'uuid': 'g1', 'name': 'Work'},
        ],
      },
    });

    test('reads a plain export: totp, hotp and steam, skipping unknown types', () async {
      final result = await codec.decode(_bytes(plain));
      expect(result.records, hasLength(3));
      expect(result.warnings, hasLength(1));

      final totp = result.records[0];
      expect(totp.title, 'Example (alice)');
      expect(totp.favorite, isTrue);
      expect(totp.fields['notes'], 'n\nTags: Work');

      final hotp = result.records[1];
      expect(hotp.fields['totp_type'], 'hotp');
      expect(hotp.fields['hotp_counter'], '7');
      expect(hotp.fields['totp_algorithm'], 'SHA256');
      expect(hotp.fields['totp_digits'], '8');

      expect(result.records[2].fields['totp_type'], 'steam');
    });

    test('an encrypted vault without a password asks for one', () {
      final encrypted = jsonEncode({
        'version': 1,
        'header': {
          'slots': [
            {'type': 1},
          ],
          'params': {'nonce': '00', 'tag': '00'},
        },
        'db': 'AAAA',
      });
      expect(
        () => codec.decode(_bytes(encrypted)),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
    });

    test('is detected by the registry ahead of Proton (which also sees "entries")', () {
      final guessed = guessPasswordFormat(fileName: 'aegis-export.json', bytes: _bytes(plain));
      expect(guessed.id, 'aegis');
    });
  });

  group('andOTP', () {
    const codec = AndOtpJsonCodec();

    final plain = jsonEncode([
      {
        'secret': _secret, 'issuer': 'Example', 'label': 'alice', 'digits': 6, 'type': 'TOTP',
        'algorithm': 'SHA1', 'thumbnail': 'Default', 'period': 30, 'tags': ['work'],
      },
      {
        'secret': _secret, 'issuer': 'Bank', 'label': 'bob', 'digits': 6, 'type': 'HOTP',
        'algorithm': 'SHA1', 'thumbnail': 'Default', 'counter': 3,
      },
      {
        'secret': _secret, 'issuer': 'Steam', 'label': 'carol', 'digits': 5, 'type': 'STEAM',
        'algorithm': 'SHA1', 'thumbnail': 'Default', 'period': 30,
      },
    ]);

    test('reads a plain backup with all three kinds', () async {
      final result = await codec.decode(_bytes(plain));
      expect(result.records, hasLength(3));
      expect(result.records[0].fields['notes'], 'Tags: work');
      expect(result.records[1].fields['totp_type'], 'hotp');
      expect(result.records[1].fields['hotp_counter'], '3');
      expect(result.records[2].fields['totp_type'], 'steam');
    });

    test('a binary (encrypted) backup without a password asks for one', () {
      final binary = Uint8List.fromList(List.filled(80, 0xFF));
      expect(
        () => codec.decode(binary),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
    });

    test('is detected by the registry', () {
      expect(guessPasswordFormat(fileName: 'otp_accounts.json', bytes: _bytes(plain)).id, 'andotp');
      expect(guessPasswordFormat(fileName: 'otp_accounts.json.aes', bytes: null).id, 'andotp');
    });
  });

  group('2FAS', () {
    const codec = TwoFasJsonCodec();

    final plain = jsonEncode({
      'schemaVersion': 4,
      'services': [
        {
          'name': 'Example', 'secret': _secret, 'groupId': 'g1',
          'otp': {'account': 'alice', 'issuer': 'Example', 'digits': 6, 'period': 30, 'algorithm': 'SHA1', 'tokenType': 'TOTP'},
        },
        {
          'name': 'Bank', 'secret': _secret,
          'otp': {'account': 'bob', 'digits': 6, 'algorithm': 'SHA1', 'tokenType': 'HOTP', 'counter': 9},
        },
        {
          'name': 'Steam', 'secret': _secret,
          'otp': {'account': 'carol', 'digits': 5, 'period': 30, 'algorithm': 'SHA1', 'tokenType': 'STEAM'},
        },
      ],
      'groups': [
        {'id': 'g1', 'name': 'Personal'},
      ],
    });

    test('reads a plain backup with all three kinds', () async {
      final result = await codec.decode(_bytes(plain));
      expect(result.records, hasLength(3));
      expect(result.records[0].fields['notes'], 'Tags: Personal');
      // No otp.issuer: falls back to the service name.
      expect(result.records[1].fields['issuer'], 'Bank');
      expect(result.records[1].fields['hotp_counter'], '9');
      expect(result.records[2].fields['totp_type'], 'steam');
    });

    test('an encrypted backup without a password asks for one', () {
      final encrypted = jsonEncode({'schemaVersion': 4, 'servicesEncrypted': 'AAAA:BBBB:CCCC'});
      expect(
        () => codec.decode(_bytes(encrypted)),
        throwsA(isA<PasswordFileIncorrectPasswordException>()),
      );
    });
  });

  group('LastPass Authenticator', () {
    const codec = LastPassAuthenticatorJsonCodec();

    test('reads accounts', () async {
      final json = jsonEncode({
        'deviceId': 'x',
        'accounts': [
          {'issuerName': 'Example', 'userName': 'alice', 'secret': _secret, 'timeStep': 30, 'digits': 6, 'algorithm': 'SHA1'},
        ],
      });
      final result = await codec.decode(_bytes(json));
      expect(result.records.single.title, 'Example (alice)');
      expect(guessPasswordFormat(fileName: 'lastpass.json', bytes: _bytes(json)).id, 'lastpass_authenticator');
    });
  });

  group('Raivo OTP', () {
    const codec = RaivoJsonCodec();

    test('reads string-typed numbers, including HOTP', () async {
      final json = jsonEncode([
        {'kind': 'TOTP', 'issuer': 'Example', 'account': 'alice', 'secret': _secret, 'algorithm': 'SHA1', 'digits': '6', 'timer': '30', 'counter': '0'},
        {'kind': 'HOTP', 'issuer': 'Bank', 'account': 'bob', 'secret': _secret, 'algorithm': 'SHA1', 'digits': '6', 'timer': '30', 'counter': '12'},
      ]);
      final result = await codec.decode(_bytes(json));
      expect(result.records, hasLength(2));
      expect(result.records[1].fields['totp_type'], 'hotp');
      expect(result.records[1].fields['hotp_counter'], '12');
      expect(guessPasswordFormat(fileName: 'raivo.json', bytes: _bytes(json)).id, 'raivo');
    });

    test('tells the person to unzip a .zip', () {
      final zip = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0]);
      expect(() => codec.decode(zip), throwsA(isA<PasswordFileFormatException>()));
    });
  });

  group('registry', () {
    test('an otpauth list is detected, but a Bitwarden export that merely contains URIs is not', () {
      expect(
        guessPasswordFormat(fileName: 'codes.txt', bytes: _bytes('otpauth://totp/A?secret=$_secret')).id,
        'txt',
      );
      final bitwarden = jsonEncode({
        'items': [
          {'login': {'totp': 'otpauth://totp/A?secret=$_secret'}},
        ],
      });
      expect(guessPasswordFormat(fileName: 'bw.json', bytes: _bytes(bitwarden)).id, 'bitwarden_json');
    });

    test('only the otpauth list is offered for export among the new formats', () {
      final exportable = kExportablePasswordFormats.map((c) => c.id);
      expect(exportable, contains('txt'));
      expect(exportable, isNot(contains('aegis')));
      expect(exportable, isNot(contains('andotp')));
    });

    test('KDBX remains the default import format', () {
      expect(kImportablePasswordFormats.first.id, 'kdbx');
    });
  });
}
