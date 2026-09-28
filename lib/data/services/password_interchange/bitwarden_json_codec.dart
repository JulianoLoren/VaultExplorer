// Bitwarden's JSON vault export (Settings -> Export vault -> .json,
// plain or password-protected).
// This format has a real type system (login/note/card/identity) that maps
// onto VaultItemType almost one-to-one, and a generic `fields` array on
// every item for anything that doesn't -- so, unlike CSV, this is a
// high-fidelity round trip for every VaultExplorer item type, not just
// logins. See docs/password-interchange.md for the exact field mapping.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/data/models/password_exchange/exchange_record.dart';
import 'package:vaultexplorer/data/models/vault_item.dart';
import 'package:vaultexplorer/data/services/password_interchange/authenticator_backup_crypto.dart';
import 'package:vaultexplorer/data/services/password_interchange/password_format_codec.dart';

// Bitwarden's own item type numbers -- fixed by their export schema, not
// something this codec invents.
const int _bwTypeLogin = 1;
const int _bwTypeSecureNote = 2;
const int _bwTypeCard = 3;
const int _bwTypeIdentity = 4;

class BitwardenJsonCodec implements PasswordFormatCodec {
  final VaultCryptoApi _crypto;
  const BitwardenJsonCodec({VaultCryptoApi crypto = kDefaultBackupCrypto}) : _crypto = crypto;

  @override
  String get id => 'bitwarden_json';

  @override
  String get displayName => 'Bitwarden (.json)';

  @override
  String get description =>
      'Bitwarden vault export (.json) -- plain or password-protected. High fidelity for every item type.';

  @override
  bool get supportsImport => true;

  @override
  bool get supportsExport => true;

  @override
  bool get isEncrypted => false;

  @override
  bool get isOptionallyEncrypted => true;

  @override
  bool looksLikeThisFormat({required String fileName, Uint8List? bytes}) {
    final lower = fileName.toLowerCase();
    if (lower.contains('bitwarden') && lower.endsWith('.json')) return true;
    if (!lower.endsWith('.json')) return false;
    if (bytes == null) return true;
    try {
      final text = utf8.decode(bytes.take(4096).toList(), allowMalformed: true);
      return text.contains('"items"') ||
          (text.contains('"encrypted"') && text.contains('"passwordProtected"')) ||
          text.contains('"encKeyValidation_DO_NOT_EDIT"');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DecodedExchange> decode(Uint8List bytes, {String? password}) async {
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) throw const FormatException('Root is not a JSON object.');
      root = decoded;
    } catch (e) {
      throw PasswordFileFormatException('Could not parse this file as JSON: $e');
    }

    final Map<String, dynamic> vault;
    if (root['encrypted'] == true) {
      if (root['passwordProtected'] == true || root.containsKey('encKeyValidation_DO_NOT_EDIT')) {
        vault = await _decryptPasswordProtected(root, password);
      } else {
        throw const PasswordFileFormatException(
          'This is an account-restricted Bitwarden export. In Bitwarden, export using the "Password protected" option instead.',
        );
      }
    } else {
      vault = root;
    }

    final rawItems = vault['items'];
    if (rawItems is! List) {
      throw const PasswordFileFormatException('This doesn\'t look like a Bitwarden vault export (no "items" array).');
    }

    final folderNames = <String, String>{};
    final rawFolders = vault['folders'];
    if (rawFolders is List) {
      for (final f in rawFolders) {
        if (f is Map && f['id'] is String && f['name'] is String) {
          folderNames[f['id'] as String] = f['name'] as String;
        }
      }
    }

    final records = <ExchangeRecord>[];
    final warnings = <String>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      try {
        final record = _itemToRecord(Map<String, dynamic>.from(raw), folderNames);
        if (record != null) records.add(record);
      } catch (e) {
        warnings.add('Skipped an item that could not be read: $e');
      }
    }
    if (records.isEmpty) {
      throw const PasswordFileFormatException('No usable items were found in this export.');
    }
    return DecodedExchange(records, warnings: warnings);
  }

  Future<Map<String, dynamic>> _decryptPasswordProtected(
    Map<String, dynamic> root,
    String? password,
  ) async {
    if (password == null || password.isEmpty) {
      throw const PasswordFileIncorrectPasswordException();
    }
    final rawSalt = root['salt'];
    final kdfType = root['kdfType'] as int? ?? 0;
    final kdfIterations = root['kdfIterations'] as int? ?? 100000;
    final encKeyValidation = root['encKeyValidation_DO_NOT_EDIT'] as String?;
    final data = root['data'] as String?;

    if (rawSalt is! String || data == null) {
      throw const PasswordFileFormatException('This Bitwarden export is malformed.');
    }
    if (kdfType != 0) {
      throw const PasswordFileFormatException(
        'Argon2id-encrypted Bitwarden exports are not supported. Re-export using PBKDF2.',
      );
    }

    final saltBytes = Uint8List.fromList(utf8.encode(rawSalt));
    final Uint8List masterKey;
    try {
      masterKey = await derivePbkdf2(
        _crypto,
        password: password,
        salt: saltBytes,
        iterations: kdfIterations,
        keyLength: 32,
        hash: Pbkdf2Hash.sha256,
      );
    } catch (_) {
      throw const PasswordFileIncorrectPasswordException();
    }

    Uint8List hkdfExpand(Uint8List prk, String info) {
      final hmac = crypto.Hmac(crypto.sha256, prk);
      final bytes = hmac.convert([...utf8.encode(info), 1]).bytes;
      return Uint8List.fromList(bytes.sublist(0, 32));
    }

    final encKey = hkdfExpand(masterKey, 'enc');
    final macKey = hkdfExpand(masterKey, 'mac');

    ({Uint8List iv, Uint8List ct, Uint8List mac}) parseCipherString(String cs) {
      final dot = cs.indexOf('.');
      if (dot < 0) throw const PasswordFileFormatException('Invalid cipher format.');
      final parts = cs.substring(dot + 1).split('|');
      if (parts.length < 3) throw const PasswordFileFormatException('Invalid cipher parts.');
      return (
        iv: base64.decode(base64.normalize(parts[0])),
        ct: base64.decode(base64.normalize(parts[1])),
        mac: base64.decode(base64.normalize(parts[2])),
      );
    }

    bool verifyMac(Uint8List macKey, Uint8List iv, Uint8List ct, Uint8List expectedMac) {
      final hmac = crypto.Hmac(crypto.sha256, macKey);
      final computed = hmac.convert([...iv, ...ct]).bytes;
      if (computed.length != expectedMac.length) return false;
      var diff = 0;
      for (var i = 0; i < computed.length; i++) {
        diff |= computed[i] ^ expectedMac[i];
      }
      return diff == 0;
    }

    try {
      if (encKeyValidation != null && encKeyValidation.isNotEmpty) {
        final val = parseCipherString(encKeyValidation);
        if (!verifyMac(macKey, val.iv, val.ct, val.mac)) {
          throw const PasswordFileIncorrectPasswordException();
        }
      }

      final d = parseCipherString(data);
      if (!verifyMac(macKey, d.iv, d.ct, d.mac)) {
        throw const PasswordFileIncorrectPasswordException();
      }

      final plain = await openAesCbc(
        _crypto,
        key: encKey,
        iv: d.iv,
        ciphertext: d.ct,
      );

      final jsonStr = utf8.decode(plain);
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        throw const PasswordFileFormatException('Decrypted Bitwarden data is not valid JSON.');
      }
      return decoded;
    } finally {
      masterKey.fillRange(0, masterKey.length, 0);
      encKey.fillRange(0, encKey.length, 0);
      macKey.fillRange(0, macKey.length, 0);
    }
  }

  ExchangeRecord? _itemToRecord(Map<String, dynamic> item, Map<String, String> folderNames) {
    final bwType = (item['type'] as num?)?.toInt();
    final name = item['name'] as String? ?? '';
    final notes = item['notes'] as String? ?? '';
    final favorite = item['favorite'] == true;
    final folderId = item['folderId'] as String?;
    final folderPath = (folderId != null && folderNames.containsKey(folderId))
        ? folderNames[folderId]!.split('/').where((s) => s.isNotEmpty).toList()
        : const <String>[];

    final fields = <String, String>{};

    switch (bwType) {
      case _bwTypeLogin:
        final login = (item['login'] as Map?)?.cast<String, dynamic>() ?? const {};
        final uris = login['uris'];
        String firstUri = '';
        if (uris is List) {
          for (final u in uris) {
            if (u is Map && u['uri'] is String && (u['uri'] as String).isNotEmpty) {
              firstUri = u['uri'] as String;
              break;
            }
          }
        }
        fields['username'] = login['username'] as String? ?? '';
        fields['password'] = login['password'] as String? ?? '';
        fields['url'] = firstUri;
        final totp = login['totp'] as String?;
        if (totp != null && totp.isNotEmpty) fields['totp_secret'] = _extractTotpSecret(totp);
        fields['notes'] = notes;
        _mergeCustomFields(item, fields);
        return ExchangeRecord(
          type: VaultItemType.password,
          title: name,
          fields: fields,
          folderPath: folderPath,
          favorite: favorite,
        );

      case _bwTypeSecureNote:
        fields['content'] = notes;
        _mergeCustomFields(item, fields);
        return ExchangeRecord(
          type: VaultItemType.secureNote,
          title: name,
          fields: fields,
          folderPath: folderPath,
          favorite: favorite,
        );

      case _bwTypeCard:
        final card = (item['card'] as Map?)?.cast<String, dynamic>() ?? const {};
        final month = card['expMonth'] as String? ?? '';
        final year = card['expYear'] as String? ?? '';
        fields['cardholder'] = card['cardholderName'] as String? ?? '';
        fields['number'] = card['number'] as String? ?? '';
        fields['expiry'] = (month.isEmpty && year.isEmpty)
            ? ''
            : '${month.padLeft(2, '0')}/${year.length >= 2 ? year.substring(year.length - 2) : year}';
        fields['cvv'] = card['code'] as String? ?? '';
        fields['notes'] = notes;
        _mergeCustomFields(item, fields);
        return ExchangeRecord(
          type: VaultItemType.paymentCard,
          title: name,
          fields: fields,
          folderPath: folderPath,
          favorite: favorite,
        );

      case _bwTypeIdentity:
        final identity = (item['identity'] as Map?)?.cast<String, dynamic>() ?? const {};
        final first = identity['firstName'] as String? ?? '';
        final middle = identity['middleName'] as String? ?? '';
        final last = identity['lastName'] as String? ?? '';
        final fullName = [first, middle, last].where((s) => s.isNotEmpty).join(' ');
        final addressParts = [
          identity['address1'],
          identity['address2'],
          identity['address3'],
          identity['city'],
          identity['state'],
          identity['postalCode'],
          identity['country'],
        ].whereType<String>().where((s) => s.isNotEmpty);
        fields['full_name'] = fullName;
        fields['national_id'] = identity['ssn'] as String? ?? '';
        fields['drivers_license'] = identity['licenseNumber'] as String? ?? '';
        fields['passport_no'] = identity['passportNumber'] as String? ?? '';
        fields['address'] = addressParts.join(', ');
        fields['phone'] = identity['phone'] as String? ?? '';
        fields['email'] = identity['email'] as String? ?? '';
        fields['notes'] = notes;
        _mergeCustomFields(item, fields);
        return ExchangeRecord(
          type: VaultItemType.identity,
          title: name,
          fields: fields,
          folderPath: folderPath,
          favorite: favorite,
        );

      default:
        fields['content'] = notes;
        _mergeCustomFields(item, fields);
        return ExchangeRecord(
          type: VaultItemType.secureNote,
          title: name.isEmpty ? '(imported item)' : name,
          fields: fields,
          folderPath: folderPath,
          favorite: favorite,
        );
    }
  }

  String _extractTotpSecret(String totp) {
    if (!totp.startsWith('otpauth://')) return totp;
    try {
      final secret = Uri.parse(totp).queryParameters['secret'];
      return secret ?? totp;
    } catch (_) {
      return totp;
    }
  }

  void _mergeCustomFields(Map<String, dynamic> item, Map<String, String> fields) {
    final raw = item['fields'];
    if (raw is! List) return;
    for (final f in raw) {
      if (f is! Map) continue;
      final name = f['name'] as String?;
      final value = f['value'];
      if (name == null || name.isEmpty || value == null) continue;
      fields.putIfAbsent(name, () => '$value');
    }
  }

  @override
  Future<Uint8List> encode(List<ExchangeRecord> records, {String? password}) async {
    final folderIds = <String, String>{};
    final folders = <Map<String, String>>[];
    String folderIdFor(List<String> path) {
      if (path.isEmpty) return '';
      final key = path.join('/');
      return folderIds.putIfAbsent(key, () {
        final id = 'f-${folderIds.length + 1}';
        folders.add({'id': id, 'name': key});
        return id;
      });
    }

    final items = records.map((r) => _recordToItem(r, folderIdFor)).toList();

    final root = {
      'encrypted': false,
      'folders': folders,
      'items': items,
    };
    final text = const JsonEncoder.withIndent('  ').convert(root);
    return Uint8List.fromList(utf8.encode(text));
  }

  Map<String, dynamic> _recordToItem(ExchangeRecord r, String Function(List<String>) folderIdFor) {
    final f = Map<String, String>.from(r.fields);
    String take(String key) => f.remove(key) ?? '';
    final folderId = folderIdFor(r.folderPath);

    final base = <String, dynamic>{
      'id': null,
      'organizationId': null,
      'folderId': folderId.isEmpty ? null : folderId,
      'favorite': r.favorite,
      'name': r.title,
      'notes': null,
      'fields': const <dynamic>[],
      'reprompt': 0,
    };

    switch (r.type) {
      case VaultItemType.password:
        final username = take('username');
        final pwd = take('password');
        final url = take('url');
        final totp = take('totp_secret');
        base['notes'] = _emptyToNull(take('notes'));
        base['type'] = _bwTypeLogin;
        base['login'] = {
          'username': _emptyToNull(username),
          'password': _emptyToNull(pwd),
          'totp': _emptyToNull(totp),
          'uris': url.isEmpty ? const <dynamic>[] : [{'match': null, 'uri': url}],
        };
        break;
      case VaultItemType.secureNote:
        base['notes'] = _emptyToNull(take('content'));
        base['type'] = _bwTypeSecureNote;
        base['secureNote'] = {'type': 0};
        break;
      case VaultItemType.paymentCard:
        final expiry = take('expiry');
        final parts = expiry.split('/');
        base['notes'] = _emptyToNull(take('notes'));
        base['type'] = _bwTypeCard;
        base['card'] = {
          'cardholderName': _emptyToNull(take('cardholder')),
          'brand': null,
          'number': _emptyToNull(take('number')),
          'expMonth': _emptyToNull(parts.isNotEmpty ? parts[0].trim() : ''),
          'expYear': _emptyToNull(parts.length > 1 ? parts[1].trim() : ''),
          'code': _emptyToNull(take('cvv')),
        };
        break;
      case VaultItemType.identity:
        final fullName = take('full_name');
        final spaceIdx = fullName.indexOf(' ');
        final first = spaceIdx == -1 ? fullName : fullName.substring(0, spaceIdx);
        final last = spaceIdx == -1 ? '' : fullName.substring(spaceIdx + 1);
        base['notes'] = _emptyToNull(take('notes'));
        base['type'] = _bwTypeIdentity;
        base['identity'] = {
          'title': null,
          'firstName': _emptyToNull(first),
          'middleName': null,
          'lastName': _emptyToNull(last),
          'address1': _emptyToNull(take('address')),
          'address2': null,
          'address3': null,
          'city': null,
          'state': null,
          'postalCode': null,
          'country': null,
          'company': null,
          'email': _emptyToNull(take('email')),
          'phone': _emptyToNull(take('phone')),
          'ssn': _emptyToNull(take('national_id')),
          'username': null,
          'passportNumber': _emptyToNull(take('passport_no')),
          'licenseNumber': _emptyToNull(take('drivers_license')),
        };
        break;
      case VaultItemType.bankAccount:
      case VaultItemType.softwareLicense:
        base['notes'] = _emptyToNull(take('notes'));
        base['type'] = _bwTypeSecureNote;
        base['secureNote'] = {'type': 0};
        break;
      case VaultItemType.authenticator:
        final account = take('account');
        final totp = take('totp_secret');
        base['notes'] = _emptyToNull(take('notes'));
        base['type'] = _bwTypeLogin;
        base['login'] = {
          'username': _emptyToNull(account),
          'password': null,
          'totp': _emptyToNull(totp),
          'uris': const <dynamic>[],
        };
        break;
    }

    if (f.isNotEmpty) {
      final existingFields = (base['fields'] as List).cast<dynamic>();
      base['fields'] = [
        ...existingFields,
        ...f.entries.map(
          (e) => {
            'name': e.key,
            'value': e.value,
            'type': kSecretExchangeFieldKeys.contains(e.key) ? 1 : 0,
            'linkedId': null,
          },
        ),
      ];
    }
    return base;
  }

  dynamic _emptyToNull(String s) => s.isEmpty ? null : s;
}