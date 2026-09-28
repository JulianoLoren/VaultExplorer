// Import-only codec for andOTP's backup: either the plain `.json` array or
// the password-encrypted `.json.aes` (a newer-format backup: 4-byte
// big-endian PBKDF2 iteration count, 12-byte salt, 12-byte IV, then
// AES-256-GCM ciphertext with its tag appended, keyed by PBKDF2-HMAC-SHA1).
// Older andOTP encrypted backups (SHA-256 of the password, AES-CBC) aren't
// handled -- re-export from a current andOTP.
//
// PBKDF2 and AES-GCM run in the native engine -- see
// authenticator_backup_crypto.dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/core/utils/totp_engine.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_backup_crypto.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_import_shared.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

class AndOtpJsonCodec implements PasswordFormatCodec {
  final VaultCryptoApi _crypto;
  const AndOtpJsonCodec({VaultCryptoApi crypto = kDefaultBackupCrypto}) : _crypto = crypto;

  static const int _saltLength = 12;
  static const int _ivLength = 12;
  static const int _tagLength = 16;

  @override
  String get id => 'andotp';

  @override
  String get displayName => 'andOTP (.json / .aes)';

  @override
  String get description =>
      'andOTP backup -- plain or password-encrypted. Time-based, counter-based (HOTP) '
      'and Steam Guard entries are imported.';

  @override
  bool get supportsImport => true;

  @override
  bool get supportsExport => false;

  @override
  bool get isEncrypted => false;

  @override
  bool get isOptionallyEncrypted => true;

  @override
  bool looksLikeThisFormat({required String fileName, Uint8List? bytes}) {
    if (fileName.toLowerCase().endsWith('.aes')) return true;
    final text = tryDecodeUtf8(bytes)?.trimLeft();
    if (text == null || !text.startsWith('[')) return false;
    return text.contains('"secret"') && text.contains('"type"') &&
        (text.contains('"thumbnail"') || text.contains('"label"'));
  }

  @override
  Future<DecodedExchange> decode(Uint8List bytes, {String? password}) async {
    final text = tryDecodeUtf8(bytes);
    final String json;
    if (text != null) {
      if (!text.trimLeft().startsWith('[')) {
        throw const PasswordFileFormatException('This doesn\'t look like an andOTP backup.');
      }
      json = text;
    } else {
      // Not text -- an encrypted backup.
      if (password == null || password.isEmpty) {
        throw const PasswordFileIncorrectPasswordException();
      }
      json = await _decrypt(bytes, password);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw const PasswordFileFormatException('This andOTP backup is malformed.');
    }
    if (decoded is! List) {
      throw const PasswordFileFormatException('This andOTP backup is malformed.');
    }
    return _parse(decoded);
  }

  Future<String> _decrypt(Uint8List bytes, String password) async {
    const headerLength = 4 + _saltLength + _ivLength;
    if (bytes.length < headerLength + _tagLength) {
      throw const PasswordFileFormatException('This andOTP backup is too short to be valid.');
    }
    final iterations = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
    final salt = Uint8List.sublistView(bytes, 4, 4 + _saltLength);
    final iv = Uint8List.sublistView(bytes, 4 + _saltLength, headerLength);
    final ciphertextAndTag = Uint8List.sublistView(bytes, headerLength);

    final key = await derivePbkdf2(
      _crypto,
      password: password,
      salt: salt,
      iterations: iterations,
      keyLength: 32,
      hash: Pbkdf2Hash.sha1,
    );
    try {
      final plain = await openAesGcm(
        _crypto,
        key: key,
        iv: iv,
        ciphertextAndTag: ciphertextAndTag,
      );
      return utf8.decode(plain);
    } on FormatException {
      throw const PasswordFileFormatException('This andOTP backup is malformed.');
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  DecodedExchange _parse(List<dynamic> entries) {
    final records = <ExchangeRecord>[];
    final warnings = <String>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final issuer = jsonStr(raw['issuer']);
      final account = jsonStr(raw['label']);
      final label = authenticatorTitle(issuer: issuer, account: account);
      try {
        final type = jsonStr(raw['type']).toLowerCase();
        final kind = switch (type) {
          'totp' || '' => OtpKind.totp,
          'hotp' => OtpKind.hotp,
          'steam' => OtpKind.steam,
          _ => null,
        };
        if (kind == null) {
          warnings.add(skippedEntryWarning(label, 'the "$type" code type isn\'t supported'));
          continue;
        }
        final secret = jsonStr(raw['secret']);
        if (secret.isEmpty) {
          warnings.add(skippedEntryWarning(label, 'it has no secret key'));
          continue;
        }
        final algo = jsonStr(raw['algorithm']);
        if (kind != OtpKind.steam && normalizeOtpAlgorithm(algo) == null) {
          warnings.add(skippedEntryWarning(label, unsupportedAlgorithmReason(algo.toUpperCase())));
          continue;
        }
        final tags = raw['tags'] is List ? (raw['tags'] as List).map(jsonStr) : const <String>[];
        records.add(
          ExchangeRecord(
            type: VaultItemType.authenticator,
            title: label,
            fields: authenticatorFields(
              issuer: issuer,
              account: account,
              secret: secret,
              kind: kind,
              algorithm: algo,
              digits: jsonInt(raw['digits']),
              period: jsonInt(raw['period']),
              counter: jsonInt(raw['counter']),
              notes: buildNotes(null, tags),
            ),
          ),
        );
      } catch (_) {
        warnings.add(skippedEntryWarning(label, 'the entry couldn\'t be read'));
      }
    }
    if (records.isEmpty) throw noImportableEntries(warnings);
    return DecodedExchange(records, warnings: warnings);
  }

  @override
  Future<Uint8List> encode(List<ExchangeRecord> records, {String? password}) async =>
      throw UnsupportedError('Exporting to andOTP isn\'t supported.');
}
