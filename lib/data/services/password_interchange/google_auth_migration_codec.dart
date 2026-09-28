// Import-only codec for Google Authenticator's "Export accounts" transfer
// code: an `otpauth-migration://offline?data=<base64>` URI (what the export
// QR code contains -- read it with any QR scanner and save the text, or
// paste several such URIs into one file, one per line, when the export was
// split across multiple QR codes). `data` is a small protobuf message; the
// handful of fields it uses are read by hand below, rather than pulling in
// a protobuf runtime and code generation for one fixed schema.
//
//   MigrationPayload { repeated OtpParameters otp_parameters = 1;
//                      int32 version = 2; int32 batch_size = 3; ... }
//   OtpParameters    { bytes secret = 1; string name = 2; string issuer = 3;
//                      enum algorithm = 4; enum digits = 5; enum type = 6;
//                      int64 counter = 7; }
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:vaultexplorer/core/utils/totp_engine.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_import_shared.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

class GoogleAuthMigrationCodec implements PasswordFormatCodec {
  const GoogleAuthMigrationCodec();

  static const String _scheme = 'otpauth-migration://';

  @override
  String get id => 'google_authenticator';

  @override
  String get displayName => 'Google Authenticator (transfer code)';

 @override
  String get description =>
      'The otpauth-migration:// code from Google Authenticator\'s "Export accounts" -- '
      'scan its QR code with the camera or import from a file. Not encrypted.';

  @override
  bool get supportsImport => true;

  @override
  bool get supportsExport => false;

  @override
  bool get isEncrypted => false;

  @override
  bool get isOptionallyEncrypted => false;

 @override
  bool looksLikeThisFormat({required String fileName, Uint8List? bytes}) {
    final lower = fileName.toLowerCase();
    if (lower.contains('google') || lower.contains('migration')) return true;
    return tryDecodeUtf8(bytes)?.contains(_scheme) ?? false;
  }

  @override
  Future<DecodedExchange> decode(Uint8List bytes, {String? password}) async {
    final text = tryDecodeUtf8(bytes);
    if (text == null || !text.contains(_scheme)) {
      throw const PasswordFileFormatException(
        'This file doesn\'t contain a Google Authenticator transfer code (otpauth-migration://...).',
      );
    }

    final records = <ExchangeRecord>[];
    final warnings = <String>[];
    var declaredBatches = 1;
    var payloads = 0;

    for (final match in RegExp('otpauth-migration://[^\\s]+').allMatches(text)) {
      final Uint8List payload;
      try {
        payload = _payloadBytes(match.group(0)!);
      } on FormatException {
        warnings.add('Skipped one transfer code that couldn\'t be read.');
        continue;
      }
      payloads++;
      try {
        final reader = _ProtoReader(payload);
        while (reader.hasMore) {
          final field = reader.next();
          if (field.number == 1 && field.value is Uint8List) {
            _addEntry(field.value as Uint8List, records, warnings);
          } else if (field.number == 3 && field.value is int) {
            declaredBatches = field.value as int;
          }
        }
      } on FormatException {
        warnings.add('A transfer code was cut off partway, so some accounts may be missing.');
      }
    }

    if (declaredBatches > payloads && payloads > 0) {
      warnings.add(
        'Google Authenticator split this export into $declaredBatches codes but only '
        '$payloads ${payloads == 1 ? 'was' : 'were'} in the file -- import the others too.',
      );
    }
    if (records.isEmpty) throw noImportableEntries(warnings);
    return DecodedExchange(records, warnings: warnings);
  }

  /// The decoded protobuf bytes of one `otpauth-migration://` URI.
  Uint8List _payloadBytes(String uri) {
    final q = uri.indexOf('data=');
    if (q < 0) throw const FormatException('No data parameter');
    var data = uri.substring(q + 5);
    final amp = data.indexOf('&');
    if (amp >= 0) data = data.substring(0, amp);
    // Percent-decoded (not form-decoded: a literal '+' is base64, not a
    // space), then tolerant of the URL-safe alphabet and missing padding.
    data = Uri.decodeComponent(data).replaceAll('-', '+').replaceAll('_', '/');
    return base64.decode(base64.normalize(data));
  }

  void _addEntry(Uint8List bytes, List<ExchangeRecord> records, List<String> warnings) {
    Uint8List secret = Uint8List(0);
    var name = '';
    var issuer = '';
    var algorithm = 0;
    var digits = 0;
    var type = 0;
    var counter = 0;

    final reader = _ProtoReader(bytes);
    while (reader.hasMore) {
      final f = reader.next();
      final v = f.value;
      if (v is Uint8List) {
        if (f.number == 1) {
          secret = v;
        } else if (f.number == 2) {
          name = utf8.decode(v, allowMalformed: true);
        } else if (f.number == 3) {
          issuer = utf8.decode(v, allowMalformed: true);
        }
      } else if (v is int) {
        if (f.number == 4) {
          algorithm = v;
        } else if (f.number == 5) {
          digits = v;
        } else if (f.number == 6) {
          type = v;
        } else if (f.number == 7) {
          counter = v;
        }
      }
    }

    // Google writes "Issuer:account" into the name when it has both.
    var account = name.trim();
    final colon = account.indexOf(':');
    if (colon >= 0) {
      if (issuer.trim().isEmpty) issuer = account.substring(0, colon);
      account = account.substring(colon + 1).trim();
    }
    issuer = issuer.trim();
    final label = authenticatorTitle(issuer: issuer, account: account);

    if (secret.isEmpty) {
      warnings.add(skippedEntryWarning(label, 'it has no secret key'));
      return;
    }
    // algorithm: 0/1 SHA1, 2 SHA256, 3 SHA512, 4 MD5.
    final algorithmName = switch (algorithm) {
      0 || 1 => 'SHA1',
      2 => 'SHA256',
      3 => 'SHA512',
      _ => null,
    };
    if (algorithmName == null) {
      warnings.add(skippedEntryWarning(
        label,
        algorithm == 4 ? unsupportedAlgorithmReason('MD5') : 'its hash algorithm isn\'t supported',
      ));
      return;
    }

    records.add(
      ExchangeRecord(
        type: VaultItemType.authenticator,
        title: label,
        fields: authenticatorFields(
          issuer: issuer,
          account: account,
          secret: base32Encode(secret),
          // type: 1 HOTP, 2 TOTP (0 unspecified -> TOTP).
          kind: type == 1 ? OtpKind.hotp : OtpKind.totp,
          algorithm: algorithmName,
          // digits: 1 six, 2 eight (0 unspecified -> six). Google's schema
          // has no period field -- every entry is the standard 30 seconds.
          digits: digits == 2 ? 8 : 6,
          counter: counter,
        ),
      ),
    );
  }

  @override
  Future<Uint8List> encode(List<ExchangeRecord> records, {String? password}) async =>
      throw UnsupportedError('Exporting to Google Authenticator isn\'t supported.');
}

/// Minimal protobuf wire-format reader: varints and length-delimited fields
/// (everything the migration schema uses), skipping fixed-width ones.
class _ProtoReader {
  _ProtoReader(this._data);

  final Uint8List _data;
  int _pos = 0;

  bool get hasMore => _pos < _data.length;

  int _varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _data.length) throw const FormatException('Truncated protobuf');
      final b = _data[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('Invalid protobuf varint');
    }
  }

  /// The next field: [value] is an `int` for a varint, a [Uint8List] for a
  /// length-delimited field (string, bytes or nested message), and 0 for a
  /// fixed-width field, which is skipped.
  ({int number, Object value}) next() {
    final tag = _varint();
    final number = tag >> 3;
    switch (tag & 0x7) {
      case 0:
        return (number: number, value: _varint());
      case 2:
        final length = _varint();
        if (length < 0 || _pos + length > _data.length) {
          throw const FormatException('Truncated protobuf field');
        }
        final view = Uint8List.sublistView(_data, _pos, _pos + length);
        _pos += length;
        return (number: number, value: view);
      case 1:
        _skip(8);
        return (number: number, value: 0);
      case 5:
        _skip(4);
        return (number: number, value: 0);
      default:
        throw const FormatException('Unsupported protobuf wire type');
    }
  }

  void _skip(int n) {
    if (_pos + n > _data.length) throw const FormatException('Truncated protobuf field');
    _pos += n;
  }
}
