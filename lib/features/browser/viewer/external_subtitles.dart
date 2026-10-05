import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';

import 'caption_track.dart';

const maxSubtitleBytes = 4 * 1024 * 1024;

class ExternalSubtitle {
  final String name;
  final CaptionTrack track;
  final String? sourcePath;
  const ExternalSubtitle(this.name, this.track, {this.sourcePath});

  factory ExternalSubtitle.parse(
    String name,
    Uint8List bytes, {
    String? sourcePath,
  }) {
    if (bytes.length > maxSubtitleBytes) throw const FormatException();
    final extension = p.extension(name).toLowerCase();
    if (extension != '.srt' && extension != '.vtt') {
      throw const FormatException();
    }
    // UTF-16 subtitles are common exports from desktop subtitle editors.
    final String text;
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      final littleEndian = bytes[0] == 0xff;
      if ((bytes.length - 2).isOdd) throw const FormatException();
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(
          littleEndian
              ? bytes[i] | (bytes[i + 1] << 8)
              : (bytes[i] << 8) | bytes[i + 1],
        );
      }
      text = String.fromCharCodes(units);
    } else {
      text = utf8.decode(bytes);
    }
    final track = extension == '.srt'
        ? CaptionTrack.subRip(text)
        : CaptionTrack.webVtt(text);
    if (track.captions.isEmpty) throw const FormatException();
    return ExternalSubtitle(name, track, sourcePath: sourcePath);
  }
}

String _stem(String path) => p
    .basenameWithoutExtension(path)
    .toLowerCase()
    .replaceAll(RegExp(r'[\s._\-\[\]()]'), '');

/// Exact names first, then language/release suffixes, then character overlap.
double subtitleNameSimilarity(String video, String subtitle) {
  final a = _stem(video);
  final b = _stem(subtitle);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 3;
  if (b.startsWith(a) && !RegExp(r'^\d').hasMatch(b.substring(a.length))) {
    return 2 + a.length / b.length;
  }
  final pairs = <String, int>{};
  for (var i = 0; i + 1 < a.length; i++) {
    final pair = a.substring(i, i + 2);
    pairs[pair] = (pairs[pair] ?? 0) + 1;
  }
  var overlap = 0;
  for (var i = 0; i + 1 < b.length; i++) {
    final pair = b.substring(i, i + 2);
    if ((pairs[pair] ?? 0) > 0) {
      overlap++;
      pairs[pair] = pairs[pair]! - 1;
    }
  }
  return a.length + b.length > 2 ? 2 * overlap / (a.length + b.length - 2) : 0;
}

Future<List<String>> findSubtitleFiles(
  VaultFileIoApi api,
  MountedContainer container,
  String video,
) async {
  final directory = p.posix.dirname(video);
  final entries = RawEntry.parseAll(
    await api.listDirectory(container, directory == '.' ? '' : directory) ?? [],
  );
  final files = entries
      .where((e) => !e.isDir && (e.extension == 'srt' || e.extension == 'vtt'))
      .map((e) => p.posix.join(directory == '.' ? '' : directory, e.name))
      .toList();
  files.sort((a, b) {
    final comparison = subtitleNameSimilarity(
      video,
      b,
    ).compareTo(subtitleNameSimilarity(video, a));
    return comparison != 0
        ? comparison
        : a.toLowerCase().compareTo(b.toLowerCase());
  });
  return files;
}

Future<ExternalSubtitle> readSubtitleFile(
  VaultFileIoApi api,
  MountedContainer container,
  String path,
) async {
  final size = await api.getFileSize(container, path);
  if (size <= 0 || size > maxSubtitleBytes) throw const FormatException();
  final bytes = await api.readFileChunk(container, path, 0, size);
  if (bytes == null) throw const FormatException();
  return ExternalSubtitle.parse(
    p.posix.basename(path),
    bytes,
    sourcePath: path,
  );
}
