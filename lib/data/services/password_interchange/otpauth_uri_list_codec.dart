// Import *and* export codec for a plain-text list of `otpauth://` URIs, one
// per line (also tolerated: several on one line, comma-separated). This is
// the lowest common denominator almost every authenticator app can write
// -- FreeOTP+, WinAuth, Ente Auth's plain-text export, Aegis's "export as
// URIs", and so on -- and so doubles as the way out of this app.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:vaultexplorer/core/utils/totp_engine.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_import_shared.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

class OtpAuthUriListCodec implements PasswordFormatCodec {
  const OtpAuthUriListCodec();

  // Also the default extension of an exported file (see the export flow in
  // password_interchange_screen.dart), hence 'txt' rather than a descriptive id.
  @override
  String get id => 'txt';

  @override
  String get displayName => 'otpauth:// URI list (.txt)';

  @override
  String get description =>
      'One otpauth:// URI per line -- the plain-text export most authenticator apps '
      '(Ente Auth, FreeOTP+, WinAuth, Aegis...) can produce. Not encrypted.';

  @override
  bool get supportsImport => true;

  @override
  bool get supportsExport => true;

  @override
  bool get isEncrypted => false;

  @override
  bool get isOptionallyEncrypted => false;

  @override
  bool looksLikeThisFormat({required String fileName, Uint8List? bytes}) =>
      // Must *start* with a URI: password-manager JSON/CSV exports often
      // carry otpauth:// URIs in their TOTP fields, and those must not be
      // mistaken for a bare list.
      tryDecodeUtf8(bytes)?.trimLeft().startsWith('otpauth://') ?? false;

  @override
  Future<DecodedExchange> decode(Uint8List bytes, {String? password}) async {
    final text = tryDecodeUtf8(bytes);
    if (text == null || !text.contains('otpauth://')) {
      throw const PasswordFileFormatException('No otpauth:// URIs were found in this file.');
    }

    final records = <ExchangeRecord>[];
    final warnings = <String>[];
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      // A line may hold several URIs joined by commas.
      for (final piece in line.split(RegExp(r',(?=\s*otpauth://)'))) {
        final uri = piece.trim();
        if (!uri.startsWith('otpauth://')) continue;
        try {
          final record = exchangeRecordFromOtpAuthUri(
            uri,
            onSkip: (reason) => warnings.add(skippedEntryWarning(_shortLabel(uri), reason)),
          );
          if (record != null) records.add(record);
        } catch (e) {
          warnings.add(skippedEntryWarning(
            _shortLabel(uri),
            e is FormatException ? e.message : 'the URI couldn\'t be read',
          ));
        }
      }
    }
    if (records.isEmpty) throw noImportableEntries(warnings);
    return DecodedExchange(records, warnings: warnings);
  }

  /// Best-effort label for a warning about a URI that couldn't be fully
  /// parsed -- never includes the secret.
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
  Future<Uint8List> encode(List<ExchangeRecord> records, {String? password}) async {
    final lines = <String>[];
    for (final record in records) {
      final uri = _uriFor(record);
      if (uri != null) lines.add(uri);
    }
    return Uint8List.fromList(utf8.encode(lines.join('\n')));
  }

  /// The otpauth:// URI for [record], or null if it has no OTP secret. An
  /// item whose `totp_secret` already *is* a full URI is written as-is.
  String? _uriFor(ExchangeRecord record) {
    final f = record.fields;
    final secretField = (f['totp_secret'] ?? '').trim();
    if (secretField.isEmpty) return null;
    if (secretField.toLowerCase().startsWith('otpauth://')) return secretField;

    final config = TotpConfig.fromFields(f);
    final issuer = (f['issuer'] ?? '').trim().isNotEmpty ? f['issuer']!.trim() : record.title;
    final account = (f['account'] ?? f['username'] ?? '').trim();
    String enc(String v) => Uri.encodeComponent(v);

    final label = account.isEmpty ? enc(issuer) : '${enc(issuer)}:${enc(account)}';
    final params = <String>[
      'secret=${enc(config.secret.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase())}',
      'issuer=${enc(issuer)}',
    ];
    switch (config.kind) {
      case OtpKind.steam:
        params.add('digits=$kSteamCodeLength');
      case OtpKind.hotp:
        params.addAll([
          'algorithm=${config.algorithm.wireName}',
          'digits=${config.digits}',
          'counter=${config.counter}',
        ]);
      case OtpKind.totp:
        params.addAll([
          'algorithm=${config.algorithm.wireName}',
          'digits=${config.digits}',
          'period=${config.period}',
        ]);
    }
    return 'otpauth://${config.kind.wireName}/$label?${params.join('&')}';
  }
}
