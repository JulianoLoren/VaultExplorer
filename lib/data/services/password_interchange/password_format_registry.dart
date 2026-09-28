import 'dart:typed_data';

import 'package:vaultexplorer/data/services/password_interchange/aegis_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/andotp_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/bitwarden_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/csv_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/google_auth_migration_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/kdbx_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/lastpass_authenticator_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/otpauth_uri_list_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/proton_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/raivo_json_codec.dart';
import 'package:vaultexplorer/data/services/password_interchange/twofas_json_codec.dart';

/// Every interchange format this build understands, in the order they
/// should be offered in the UI. Adding a new format is just adding another
/// [PasswordFormatCodec] here -- nothing else in this feature needs to know
/// about individual formats.
const List<PasswordFormatCodec> kPasswordFormatCodecs = [
  KdbxCodec(),
  // Order matters beyond the picker: guessPasswordFormat returns the first
  // codec whose looksLikeThisFormat says yes. Proton's sniffer accepts any
  // .json mentioning "entries" -- which every plain Aegis export does -- so
  // the dedicated authenticator apps (whose sniffers all require markers
  // specific to their own format) are checked before Proton and Bitwarden.
  // KDBX stays first so it remains the default import/export format.
  AegisJsonCodec(),
  AndOtpJsonCodec(),
  TwoFasJsonCodec(),
  GoogleAuthMigrationCodec(),
  LastPassAuthenticatorJsonCodec(),
  RaivoJsonCodec(),
  OtpAuthUriListCodec(),
  ProtonJsonCodec(),
  BitwardenJsonCodec(),
  CsvCodec(),
];

List<PasswordFormatCodec> get kImportablePasswordFormats =>
    kPasswordFormatCodecs.where((c) => c.supportsImport).toList();

List<PasswordFormatCodec> get kExportablePasswordFormats =>
    kPasswordFormatCodecs.where((c) => c.supportsExport).toList();

/// Best-guess codec for a picked file, by content signature first (more
/// reliable than a possibly-renamed extension) and file name second. Falls
/// back to CSV -- the most permissive/least specific format -- if nothing
/// else matches, so the picker always has a sensible default rather than
/// nothing selected.
PasswordFormatCodec guessPasswordFormat({required String fileName, Uint8List? bytes}) {
  for (final codec in kImportablePasswordFormats) {
    if (codec.looksLikeThisFormat(fileName: fileName, bytes: bytes)) return codec;
  }
  return kPasswordFormatCodecs.firstWhere((c) => c.id == 'csv');
}
