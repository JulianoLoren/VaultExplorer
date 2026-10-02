import 'package:flutter/services.dart';

const _textEncodingChannel = MethodChannel(
  'com.aeidolon.vaultexplorer/text_encoding',
);

/// An Android-supported charset used by the text editor.
///
/// The list and conversions come from `java.nio.charset.Charset`, matching
/// Material Files' use of `Charset.availableCharsets()`.
class EditorTextEncoding {
  final String name;
  final String label;
  final List<int> _bom;

  const EditorTextEncoding(this.name, this.label, {List<int> bom = const []})
    : _bom = bom;

  static const utf8 = EditorTextEncoding('UTF-8', 'UTF-8');
  static const utf8Bom = EditorTextEncoding(
    'UTF-8',
    'UTF-8 with BOM',
    bom: [0xEF, 0xBB, 0xBF],
  );
  static const utf16Le = EditorTextEncoding(
    'UTF-16LE',
    'UTF-16 LE',
    bom: [0xFF, 0xFE],
  );
  static const utf16Be = EditorTextEncoding(
    'UTF-16BE',
    'UTF-16 BE',
    bom: [0xFE, 0xFF],
  );

  static Future<List<EditorTextEncoding>> available() async {
    final charsets = await _textEncodingChannel.invokeListMethod<Object?>(
      'availableCharsets',
    );
    if (charsets == null) {
      throw PlatformException(
        code: 'NO_CHARSETS',
        message: 'The platform did not return its available charsets.',
      );
    }
    return charsets
        .map((entry) {
          final charset = Map<Object?, Object?>.from(entry! as Map);
          final name = charset['name']! as String;
          final label = charset['displayName']! as String;
          return EditorTextEncoding(name, label);
        })
        .toList(growable: false);
  }

  static EditorTextEncoding detect(Uint8List bytes) {
    if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) return utf8Bom;
    if (_startsWith(bytes, const [0xFF, 0xFE])) return utf16Le;
    if (_startsWith(bytes, const [0xFE, 0xFF])) return utf16Be;
    return utf8;
  }

  Future<String> decode(Uint8List bytes) async {
    final payload = _withoutPrefix(bytes, _bom);
    return _textEncodingChannel
        .invokeMethod<String>('decode', {'charset': name, 'bytes': payload})
        .then((text) => text!);
  }

  Future<Uint8List> encode(String text) async {
    final bytes = await _textEncodingChannel.invokeMethod<Uint8List>('encode', {
      'charset': name,
      'text': text,
    });
    if (bytes == null || _bom.isEmpty) return bytes ?? Uint8List(0);
    return Uint8List.fromList([..._bom, ...bytes]);
  }

  @override
  bool operator ==(Object other) =>
      other is EditorTextEncoding &&
      name == other.name &&
      _sameBytes(_bom, other._bom);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(_bom));
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

Uint8List _withoutPrefix(Uint8List bytes, List<int> prefix) =>
    prefix.isNotEmpty && _startsWith(bytes, prefix)
    ? Uint8List.sublistView(bytes, prefix.length)
    : bytes;
