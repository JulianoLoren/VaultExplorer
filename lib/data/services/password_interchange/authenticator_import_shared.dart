// Shared building blocks for every codec in this folder that imports from a
// dedicated authenticator app (as opposed to a password manager's own TOTP
// field -- see bitwarden_json_codec.dart/proton_json_codec.dart for those).
// Kept separate from password_format_codec.dart itself since none of this
// is part of the codec *interface* -- just logic every one of these codecs
// would otherwise duplicate.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:vaultexplorer/core/utils/totp_engine.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

/// "Issuer (Account)" -- the convention essentially every authenticator
/// app, this one included (see totp_code_tile.dart), already displays an
/// entry under. Falls back gracefully when one half is missing.
String authenticatorTitle({required String issuer, required String account}) {
  final i = issuer.trim();
  final a = account.trim();
  if (i.isEmpty) return a.isEmpty ? '(untitled)' : a;
  return a.isEmpty ? i : '$i ($a)';
}

/// Normalizes a source app's hash-algorithm name to the canonical
/// `SHA1`/`SHA256`/`SHA512` [TotpAlgorithm] understands ("SHA-256",
/// "sha_256" and "Sha256" all resolve the same way). Blank means the
/// universal default, SHA1. Returns null for anything else (MD5, SHA224,
/// SHA384, GOST...) -- those aren't imported, since [TotpEngine] would
/// silently generate codes under the wrong hash.
String? normalizeOtpAlgorithm(String? raw) {
  final n = (raw ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return switch (n) {
    '' || 'SHA1' => 'SHA1',
    'SHA256' => 'SHA256',
    'SHA512' => 'SHA512',
    _ => null,
  };
}

/// Builds the field map [VaultItemTemplate.fieldsFor]'s
/// `VaultItemType.authenticator` case expects, applying the SHA1/6-digit/
/// 30-second defaults [TotpConfig.fromFields] itself falls back to at
/// generation time -- kept in sync here so an import preview's subtitle
/// already reflects what will actually be generated, rather than showing a
/// blank field that's silently defaulted later.
///
/// [kind] decides the shape: Steam Guard entries are pinned to its own
/// protocol (SHA1, five characters, 30 seconds); HOTP entries carry their
/// [counter] and no period; plain TOTP omits `totp_type` entirely, exactly
/// like an item created by hand.
Map<String, String> authenticatorFields({
  required String issuer,
  required String account,
  required String secret,
  OtpKind kind = OtpKind.totp,
  String? algorithm,
  int? digits,
  int? period,
  int? counter,
  String? notes,
}) {
  final fields = <String, String>{
    'issuer': issuer,
    'account': account,
    'totp_secret': secret,
  };
  switch (kind) {
    case OtpKind.steam:
      fields['totp_type'] = OtpKind.steam.wireName;
      fields['totp_algorithm'] = 'SHA1';
      fields['totp_digits'] = '$kSteamCodeLength';
      fields['totp_period'] = '30';
    case OtpKind.hotp:
      fields['totp_type'] = OtpKind.hotp.wireName;
      fields['totp_algorithm'] = normalizeOtpAlgorithm(algorithm) ?? 'SHA1';
      fields['totp_digits'] = '${(digits == null || digits <= 0) ? 6 : digits}';
      fields['hotp_counter'] = '${(counter == null || counter < 0) ? 0 : counter}';
    case OtpKind.totp:
      fields['totp_algorithm'] = normalizeOtpAlgorithm(algorithm) ?? 'SHA1';
      fields['totp_digits'] = '${(digits == null || digits <= 0) ? 6 : digits}';
      fields['totp_period'] = '${(period == null || period <= 0) ? 30 : period}';
  }
  if (notes != null && notes.trim().isNotEmpty) fields['notes'] = notes.trim();
  return fields;
}

/// Folds a source app's free-text note and its tags/groups into the one
/// `notes` field an authenticator item has.
String? buildNotes(String? note, Iterable<String> tags) {
  final parts = <String>[];
  if (note != null && note.trim().isNotEmpty) parts.add(note.trim());
  final cleaned = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
  if (cleaned.isNotEmpty) parts.add('Tags: ${cleaned.join(', ')}');
  return parts.isEmpty ? null : parts.join('\n');
}

/// One line for a codec's `DecodedExchange.warnings` -- reused so the
/// wording is the same regardless of which app's export triggered it.
String skippedEntryWarning(String label, String reason) =>
    'Skipped "$label": $reason.';

String unsupportedAlgorithmReason(String algorithm) =>
    '$algorithm isn\'t a supported hash algorithm';

/// The exception a codec throws when it read a file fine but nothing in it
/// could be imported. Carries the first few skip reasons in its message,
/// since a thrown exception replaces the preview (and so its warnings).
PasswordFileFormatException noImportableEntries(List<String> warnings) {
  if (warnings.isEmpty) {
    return const PasswordFileFormatException('No codes were found in this file.');
  }
  final shown = warnings.take(3).join(' ');
  final more = warnings.length > 3 ? ' (and ${warnings.length - 3} more skipped)' : '';
  return PasswordFileFormatException('No importable codes were found. $shown$more');
}

// ── small parsing helpers shared by the JSON-based codecs ───────────────────

/// Decodes [bytes] as UTF-8 (dropping a leading BOM), or null if they
/// aren't valid UTF-8 text -- which is how a codec cheaply tells a text
/// export from an encrypted binary one.
String? tryDecodeUtf8(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  } catch (_) {
    return null;
  }
}

/// A JSON value as trimmed text ('' for null).
String jsonStr(Object? v) => v == null ? '' : '$v'.trim();

/// A JSON value as an int, tolerating numbers stored as strings (Raivo
/// writes every number that way).
int? jsonInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

// ── otpauth:// URIs ─────────────────────────────────────────────────────────

/// Parses one `otpauth://totp/...`, `otpauth://hotp/...` or
/// `otpauth://steam/...` URI (the "Key Uri Format" Google Authenticator
/// popularized, and which every app in this folder can also produce as a
/// plain-text export) into an [ExchangeRecord]. Returns null -- after
/// reporting why via [onSkip] -- for a URI using an algorithm this app
/// can't generate codes for; throws [FormatException] for a URI too
/// malformed to read at all (no scheme, no secret, unknown type...).
ExchangeRecord? exchangeRecordFromOtpAuthUri(
  String rawUri, {
  void Function(String reason)? onSkip,
}) {
  // An otpauth URI never legitimately carries a fragment, but a label with a
  // literal (un-escaped) '#' in it -- "Company #1" -- would otherwise cut the
  // URI short there and lose its query string, secret included.
  final uri = Uri.parse(rawUri.trim().replaceAll('#', '%23'));
  if (uri.scheme != 'otpauth') {
    throw FormatException('Not an otpauth:// URI: $rawUri');
  }

  final qp = uri.queryParameters;
  final secret = qp['secret'];
  if (secret == null || secret.isEmpty) {
    throw const FormatException('Missing "secret" parameter');
  }

  final kind = switch (uri.host.toLowerCase()) {
    'totp' => OtpKind.totp,
    'hotp' => OtpKind.hotp,
    'steam' => OtpKind.steam,
    final other => throw FormatException('Unsupported otpauth type: $other'),
  };

  var path = uri.path;
  if (path.startsWith('/')) path = path.substring(1);
  path = Uri.decodeComponent(path);

  var issuer = qp['issuer'] ?? '';
  var account = path;
  final colon = path.indexOf(':');
  if (colon >= 0) {
    account = path.substring(colon + 1).trim();
    if (issuer.isEmpty) issuer = path.substring(0, colon);
  }

  if (kind != OtpKind.steam && normalizeOtpAlgorithm(qp['algorithm']) == null) {
    onSkip?.call(unsupportedAlgorithmReason((qp['algorithm'] ?? '').toUpperCase()));
    return null;
  }

  return ExchangeRecord(
    type: VaultItemType.authenticator,
    title: authenticatorTitle(issuer: issuer, account: account),
    fields: authenticatorFields(
      issuer: issuer,
      account: account,
      secret: secret,
      kind: kind,
      algorithm: qp['algorithm'],
      digits: int.tryParse(qp['digits'] ?? ''),
      period: int.tryParse(qp['period'] ?? ''),
      counter: int.tryParse(qp['counter'] ?? ''),
    ),
  );
}
