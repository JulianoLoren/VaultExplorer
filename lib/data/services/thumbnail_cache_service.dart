import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:vaultexplorer/core/api/vault_crypto_api.dart';
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/api/vault_hash_api.dart';
import 'package:vaultexplorer/core/utils/byte_budget_cache.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/core/utils/ve_log.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/models/thumbnail_cache_mode.dart';
import 'package:vaultexplorer/data/models/thumbnail_quality.dart';
import 'package:vaultexplorer/data/services/app_cache_encryption.dart';

import 'media_aspect_ratio_cache.dart';

part 'thumbnail_cache_service.g.dart';

@Riverpod(keepAlive: true)
ThumbnailCacheService thumbnailCacheService(Ref ref) =>
    const ThumbnailCacheService();

/// Three-tier thumbnail cache with immutable pack-file storage for in-container mode.
class ThumbnailCacheService {
  const ThumbnailCacheService();

  static VaultFileIoApi? _fileIoApi;
  static VaultCryptoApi? _cryptoApi;
  static VaultHashApi? _hashApi;

  static void configure({
    required VaultFileIoApi fileIoApi,
    required VaultCryptoApi cryptoApi,
    required VaultHashApi hashApi,
  }) {
    _fileIoApi = fileIoApi;
    _cryptoApi = cryptoApi;
    _hashApi = hashApi;
  }

  static VaultFileIoApi get _fileIo =>
      _fileIoApi ??
      (throw StateError(
        'ThumbnailCacheService must be configured during app startup.',
      ));

  static VaultCryptoApi get _crypto =>
      _cryptoApi ??
      (throw StateError(
        'ThumbnailCacheService must be configured during app startup.',
      ));

  static VaultHashApi get _hash =>
      _hashApi ??
      (throw StateError(
        'ThumbnailCacheService must be configured during app startup.',
      ));

  // ── Instance Method Forwarders ─────────────────────────────────────────────

  Uint8List? peekMemory(
    MountedContainer container,
    String filePath, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
  ]) => getFromMemory(container, filePath, quality);

  void cacheInMemory(
    MountedContainer container,
    String filePath,
    Uint8List data, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
    int? width,
    int? height,
  ]) => putInMemory(container, filePath, data, quality, width, height);

  Future<Uint8List?> fetch({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
  }) => get(
    container: container,
    filePath: filePath,
    mode: mode,
    quality: quality,
  );

  Future<(Uint8List bytes, int? width, int? height)?> fetchWithSize({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
  }) => getWithSize(
    container: container,
    filePath: filePath,
    mode: mode,
    quality: quality,
  );

  (Uint8List bytes, int? width, int? height)? peekMemoryWithSize(
    MountedContainer container,
    String filePath, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
  ]) => getWithSizeFromMemory(container, filePath, quality);

  Future<void> store({
    required MountedContainer container,
    required String filePath,
    required Uint8List data,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
    int? width,
    int? height,
  }) => put(
    container: container,
    filePath: filePath,
    data: data,
    mode: mode,
    quality: quality,
    width: width,
    height: height,
  );

  Future<void> invalidate(
    MountedContainer container,
    String filePath, {
    List<ThumbnailQuality> qualities = const [ThumbnailQuality.defaultQuality],
  }) => invalidateFile(container, filePath, qualities: qualities);

  Future<void> clearAppCache(MountedContainer container) =>
      clearAppCacheFor(container);

  Future<void> clearAppCacheForUri(String uri) => clearAppCacheByUri(uri);

  Future<void> clearInContainerCacheForUri(String uri) =>
      clearInContainerCacheByUri(uri);

  static const _channel = MethodChannel('com.aeidolon.vaultexplorer/engine');

  // ── Constants ──────────────────────────────────────────────────────────────
  static const inContainerDir = '.thumbcache';
  static const inContainerIndexFile = '.thumbcache/index.bin';
  static const _gcmNonceSize = 12;
  static const _gcmTagSize = 16;
  static const _inContainerReadCap = 8 * 1024 * 1024; // 8 MB

  // ── Tier 1: Static In-Memory Byte-Budgeted LRU ────────────────────────────
  static const int _memoryMaxBytes = 24 * 1024 * 1024;
  static final _memoryCache = ByteBudgetCache(_memoryMaxBytes);
  static final Map<String, String> _latestKeyByFile = {};
  static final Map<String, (int width, int height)> _sizeCache = {};

  static String _filePrefix(MountedContainer container, String filePath) =>
      '${container.volId}:${container.mountedAt.millisecondsSinceEpoch}:$filePath|';

  static String? _findResidentKeyForFile(
    MountedContainer container,
    String filePath,
  ) {
    final prefix = _filePrefix(container, filePath);
    final key = _latestKeyByFile[prefix];
    if (key == null) return null;
    if (_memoryCache.containsKey(key)) return key;
    _latestKeyByFile.remove(prefix);
    return null;
  }

  static void _pruneKeyIndex() {
    _latestKeyByFile.removeWhere((_, key) => !_memoryCache.containsKey(key));
  }

  static void resizeMemoryBudget(int newMaxBytes) =>
      _memoryCache.resize(newMaxBytes);

  static void trimMemoryToFraction(double fraction) =>
      _memoryCache.trimToFraction(fraction);

  // ── AES Key & Root Path Helpers ───────────────────────────────────────────
  static Future<Uint8List>? _keyFuture;
  static Future<Uint8List> getOrFetchKey() =>
      _keyFuture ??= AppCacheEncryption.getEncryptionKey();

  static Future<String>? _appCacheRootFuture;

  static Future<String> _getAppCacheRoot() {
    return _appCacheRootFuture ??= getApplicationSupportDirectory().then(
      (d) => d.path,
    );
  }

  static Future<String> _thumbDir(MountedContainer container) async {
    final root = await _getAppCacheRoot();
    final key = await _encodeKey(container.uri);
    return '$root/thumbs/$key';
  }

  static Future<String> _encodeKey(String value) {
    return _hash.hashBytesMd5(Uint8List.fromList(utf8.encode(value)));
  }

  static String _qualifiedPath(String filePath, ThumbnailQuality quality) =>
      '$filePath|${quality.size}|${quality.quality}';

  static String _memKey(
    MountedContainer container,
    String filePath,
    ThumbnailQuality quality,
  ) =>
      '${container.volId}:${container.mountedAt.millisecondsSinceEpoch}:'
      '${_qualifiedPath(filePath, quality)}';

  // ── AES-GCM Helpers ────────────────────────────────────────────────────────

  static Future<Uint8List?> _decrypt(Uint8List raw, Uint8List key) async {
    if (raw.length <= _gcmNonceSize + _gcmTagSize) return null;
    try {
      final iv = raw.sublist(0, _gcmNonceSize);
      final ciphertextAndTag = raw.sublist(_gcmNonceSize);
      return await _crypto.aesGcmDecrypt(
        key: key,
        iv: iv,
        ciphertextAndTag: ciphertextAndTag,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _encrypt(Uint8List data, Uint8List key) async {
    final rng = Random.secure();
    final iv = Uint8List(_gcmNonceSize);
    for (int i = 0; i < _gcmNonceSize; i++) {
      iv[i] = rng.nextInt(256);
    }
    final encryptedAndTag = await _crypto.aesGcmEncrypt(
      key: key,
      iv: iv,
      plaintext: data,
    );
    if (encryptedAndTag == null) {
      throw Exception('AES-GCM encryption failed');
    }
    final out = Uint8List(_gcmNonceSize + encryptedAndTag.length);
    out.setRange(0, _gcmNonceSize, iv);
    out.setRange(_gcmNonceSize, out.length, encryptedAndTag);
    return out;
  }

  // ── Tier 1: Memory Helpers ────────────────────────────────────────────────

  static Uint8List? getFromMemory(
    MountedContainer container,
    String filePath, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
  ]) {
    final key = _memKey(container, filePath, quality);
    final stored = _memoryCache[key];
    if (stored != null) {
      if (_looksLikeValidImage(stored)) return stored;
      _memoryCache.remove(key);
    }

    final matchedKey = _findResidentKeyForFile(container, filePath);
    if (matchedKey != null) {
      final alt = _memoryCache[matchedKey];
      if (alt != null) {
        if (_looksLikeValidImage(alt)) return alt;
        _memoryCache.remove(matchedKey);
      }
    }
    return null;
  }

  static (Uint8List bytes, int? width, int? height)? getWithSizeFromMemory(
    MountedContainer container,
    String filePath, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
  ]) {
    final key = _memKey(container, filePath, quality);
    final stored = _memoryCache[key];
    if (stored != null) {
      if (_looksLikeValidImage(stored)) {
        final size = _sizeCache[key];
        return (stored, size?.$1, size?.$2);
      }
      _memoryCache.remove(key);
    }

    final matchedKey = _findResidentKeyForFile(container, filePath);
    if (matchedKey != null) {
      final alt = _memoryCache[matchedKey];
      if (alt != null) {
        if (_looksLikeValidImage(alt)) {
          final size = _sizeCache[matchedKey];
          return (alt, size?.$1, size?.$2);
        }
        _memoryCache.remove(matchedKey);
      }
    }
    return null;
  }

  static void putInMemory(
    MountedContainer container,
    String filePath,
    Uint8List data, [
    ThumbnailQuality quality = ThumbnailQuality.defaultQuality,
    int? width,
    int? height,
  ]) {
    if (!_looksLikeValidImage(data)) return;

    final key = _memKey(container, filePath, quality);
    _memoryCache[key] = data;
    _latestKeyByFile[_filePrefix(container, filePath)] = key;
    if (_latestKeyByFile.length > 2048 &&
        _latestKeyByFile.length > _memoryCache.length * 4) {
      _pruneKeyIndex();
    }

    if (width != null && height != null && width > 0 && height > 0) {
      _sizeCache[key] = (width, height);
      MediaAspectRatioCache.put(container, filePath, width, height);
    }
  }

  // ── Public: Read ──────────────────────────────────────────────────────────

  static Future<Uint8List?> get({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
  }) async {
    final result = await getWithSize(
      container: container,
      filePath: filePath,
      mode: mode,
      quality: quality,
    );
    return result?.$1;
  }

  static Future<(Uint8List bytes, int? width, int? height)?> getWithSize({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
  }) async {
    if (mode == ThumbnailCacheMode.disabled) return null;

    // Tier 1: In-memory LRU
    final mem = getWithSizeFromMemory(container, filePath, quality);
    if (mem != null) return mem;

    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final dir = await _thumbDir(container);
        final cacheKey = await _encodeKey(_qualifiedPath(filePath, quality));
        var file = File('$dir/$cacheKey');

        if (!await file.exists()) {
          final baseKey = await _encodeKey(filePath);
          file = File('$dir/$baseKey');
        }

        final Uint8List raw;
        try {
          raw = await file.readAsBytes();
        } on PathNotFoundException {
          return null;
        } catch (_) {
          return null;
        }

        if (raw.length <= _gcmNonceSize + _gcmTagSize) return null;

        final key = await getOrFetchKey();
        final decrypted = await _decrypt(raw, key);
        if (decrypted == null || decrypted.isEmpty) return null;

        final bytes = decrypted;
        if (!_looksLikeValidImage(bytes)) return null;

        final dims = _extractImageDimensions(bytes);
        final width = dims?.$1;
        final height = dims?.$2;

        putInMemory(container, filePath, bytes, quality, width, height);
        return (bytes, width, height);
      } else {
        // Mode: inContainer
        final keyHex = await _encodeKey(_qualifiedPath(filePath, quality));

        // 1. Check in-memory pending flush queue
        final pending = _getPackQueue(container).getPending(keyHex);
        if (pending != null) {
          putInMemory(container, filePath, pending.data, quality, pending.width, pending.height);
          return (pending.data, pending.width, pending.height);
        }

        // 2. Query binary pack index
        final entry = await _getInContainerPackEntry(container, keyHex);
        if (entry != null) {
          final packName = 'pack_${entry.packId.toString().padLeft(4, '0')}.bin';
          final chunk = await _fileIo.readFileChunk(
            container,
            '$inContainerDir/$packName',
            entry.offset,
            entry.length,
          );
          if (chunk != null && _looksLikeValidImage(chunk)) {
            putInMemory(container, filePath, chunk, quality, entry.width, entry.height);
            return (chunk, entry.width, entry.height);
          }
        }

        // 3. Backward compatibility fallback: check legacy loose file
        final legacyPath = '$inContainerDir/$keyHex';
        final stored = await _fileIo.readFileChunk(
          container,
          legacyPath,
          0,
          _inContainerReadCap,
        );
        if (stored != null && stored.isNotEmpty && _looksLikeValidImage(stored)) {
          final dims = _extractImageDimensions(stored);
          final width = dims?.$1;
          final height = dims?.$2;
          putInMemory(container, filePath, stored, quality, width, height);
          return (stored, width, height);
        }
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  // ── Public: Write ─────────────────────────────────────────────────────────

  static Future<void> put({
    required MountedContainer container,
    required String filePath,
    required Uint8List data,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
    int? width,
    int? height,
  }) {
    if (mode == ThumbnailCacheMode.disabled || data.isEmpty) {
      return Future.value();
    }

    putInMemory(container, filePath, data, quality, width, height);

    if (!_looksLikeValidImage(data)) {
      return Future.value();
    }

    final dedupKey =
        '${mode.name}:${container.volId}:'
        '${container.mountedAt.millisecondsSinceEpoch}:'
        '${_qualifiedPath(filePath, quality)}';
    final existing = _inFlightPuts[dedupKey];
    if (existing != null) return existing;

    final future = _putInternal(
      container: container,
      filePath: filePath,
      data: data,
      mode: mode,
      quality: quality,
      width: width,
      height: height,
    );
    _inFlightPuts[dedupKey] = future;
    return future.whenComplete(() {
      if (identical(_inFlightPuts[dedupKey], future)) {
        _inFlightPuts.remove(dedupKey);
      }
    });
  }

  static Future<void> _putInternal({
    required MountedContainer container,
    required String filePath,
    required Uint8List data,
    required ThumbnailCacheMode mode,
    required ThumbnailQuality quality,
    int? width,
    int? height,
  }) async {
    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final dirPath = await _thumbDir(container);

        if (!_ensuredThumbDirs.containsKey(dirPath)) {
          _ensuredThumbDirs[dirPath] = Directory(
            dirPath,
          ).create(recursive: true).then((_) {});
        }
        await _ensuredThumbDirs[dirPath];

        final cacheKey = await _encodeKey(_qualifiedPath(filePath, quality));
        final file = File('$dirPath/$cacheKey');
        final key = await getOrFetchKey();

        // Direct write to target file
        final encrypted = await _encrypt(data, key);
        await file.writeAsBytes(encrypted, flush: false);

        if (++_putWriteCount % 25 == 0) {
          unawaited(enforceDiskBudget());
        }
      } else {
        // Mode: inContainer
        final keyHex = await _encodeKey(_qualifiedPath(filePath, quality));
        final resolvedDims = (width != null && height != null && width > 0 && height > 0)
            ? (width, height)
            : _extractImageDimensions(data) ?? (180, 180);

        final queue = _getPackQueue(container);
        await queue.enqueue(
          _PendingPackThumb(
            keyHex: keyHex,
            data: data,
            width: resolvedDims.$1,
            height: resolvedDims.$2,
          ),
          _fileIo,
        );

        if (++_inContainerPutWriteCount % 25 == 0) {
          unawaited(enforceInContainerDiskBudget(container));
        }
      }
    } catch (_) {
      // Disposable cache write failure; safe to ignore
    }
  }

  // ── In-Container Pack-File Architecture ────────────────────────────────────

  static final Map<String, _InContainerPackIndex> _inContainerIndices = {};
  static final Map<String, _InContainerPackQueue> _inContainerQueues = {};

  static _InContainerPackQueue _getPackQueue(MountedContainer container) {
    return _inContainerQueues.putIfAbsent(
      container.uri.toString(),
      () => _InContainerPackQueue(container),
    );
  }

  static Future<_PackEntry?> _getInContainerPackEntry(
    MountedContainer container,
    String keyHex,
  ) async {
    final uriStr = container.uri.toString();
    var index = _inContainerIndices[uriStr];
    if (index == null) {
      index = await _loadInContainerIndex(container);
      _inContainerIndices[uriStr] = index;
    }
    return index.entries[keyHex];
  }

  static Future<_InContainerPackIndex> _loadInContainerIndex(
    MountedContainer container,
  ) async {
    try {
      final bytes = await _fileIo.readWholeFile(container, inContainerIndexFile);
      if (bytes != null && bytes.length >= 16) {
        final byteData = ByteData.sublistView(bytes);
        final magic = utf8.decode(bytes.sublist(0, 4));
        // Reject legacy TPK1 format to self-heal any previous corrupt indices
        if (magic == 'TPK2') {
          final nextPackId = byteData.getUint16(6);
          final entryCount = byteData.getUint32(12);

          final entries = <String, _PackEntry>{};
          var offset = 16;
          for (var i = 0; i < entryCount && offset + 32 <= bytes.length; i++) {
            final keyHex = _bytesToHex(bytes.sublist(offset, offset + 16));
            final packId = byteData.getUint16(offset + 16);
            final chunkOffset = byteData.getUint32(offset + 18);
            final chunkLength = byteData.getUint32(offset + 22);
            final width = byteData.getUint16(offset + 26);
            final height = byteData.getUint16(offset + 28);

            entries[keyHex] = _PackEntry(
              packId: packId,
              offset: chunkOffset,
              length: chunkLength,
              width: width,
              height: height,
            );
            offset += 32;
          }

          return _InContainerPackIndex(
            nextPackId: nextPackId,
            entries: entries,
          );
        }
      }
    } catch (_) {}

    return _InContainerPackIndex(
      nextPackId: 0,
      entries: {},
    );
  }

  static Uint8List _serializeIndex(_InContainerPackIndex index) {
    final totalSize = 16 + index.entries.length * 32;
    final buffer = Uint8List(totalSize);
    final bd = ByteData.sublistView(buffer);

    buffer.setRange(0, 4, utf8.encode('TPK2'));
    bd.setUint16(4, 2); // Version 2
    bd.setUint16(6, index.nextPackId);
    bd.setUint32(8, 0); // Reserved
    bd.setUint32(12, index.entries.length);

    var offset = 16;
    for (final entry in index.entries.entries) {
      final keyBytes = _hexToBytes(entry.key);
      buffer.setRange(offset, offset + 16, keyBytes);
      bd.setUint16(offset + 16, entry.value.packId);
      bd.setUint32(offset + 18, entry.value.offset);
      bd.setUint32(offset + 22, entry.value.length);
      bd.setUint16(offset + 26, entry.value.width);
      bd.setUint16(offset + 28, entry.value.height);
      bd.setUint16(offset + 30, 0); // Reserved
      offset += 32;
    }

    return buffer;
  }

  static String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _hexToBytes(String hex) {
    final len = min(16, hex.length ~/ 2);
    final result = Uint8List(16);
    for (var i = 0; i < len; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  // ── Cache Invalidation & Management ────────────────────────────────────────

 static Duration inContainerDebounceDuration = const Duration(milliseconds: 2500);

  /// Called on every container lock (F-16). Flushes any pending in-container
  /// pack batch to disk before wiping the decrypted memory tier.
  static Future<void> clearAppCacheFor(MountedContainer container) async {
    final queue = _inContainerQueues[container.uri.toString()];
    if (queue != null) {
      try {
        await queue.flushNow();
      } catch (_) {}
    }
    _memoryCache.removeWhere((key) => key.startsWith('${container.volId}:'));
    _latestKeyByFile.removeWhere(
        (prefix, _) => prefix.startsWith('${container.volId}:'));
    _sizeCache.removeWhere((key, _) => key.startsWith('${container.volId}:'));
  }

  static Future<void> clearAppCacheByUri(String uri) async {
    _ensuredThumbDirs.remove(uri);
    try {
      final root = await _getAppCacheRoot();
      final key = await _encodeKey(uri);
      final dirPath = '$root/thumbs/$key';
      _ensuredThumbDirs.remove(dirPath);

      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
    _memoryCache.clear();
    _latestKeyByFile.clear();
    _sizeCache.clear();
  }

  static Future<void> clearInContainerCacheByUri(String uri) async {
    _ensuredThumbDirs.remove(uri);
    _inContainerIndices.remove(uri);
    final queue = _inContainerQueues.remove(uri);
    queue?.dispose();
    try {
      final entries = await _channel.invokeMethod<List<Object?>>(
        'listDirectory',
        {'filePath': uri, 'dirPath': inContainerDir},
      );
      if (entries != null) {
        final casted = entries.cast<String>();
        for (final raw in casted) {
          if (raw.startsWith('System:')) continue;
          final name = RawEntry.parse(raw).name;
          await _channel.invokeMethod<bool>('deleteFile', {
            'filePath': uri,
            'fileName': '$inContainerDir/$name',
          });
        }
      }
      await _channel.invokeMethod<bool>('deleteFile', {
        'filePath': uri,
        'fileName': inContainerDir,
      });
    } catch (_) {
      rethrow;
    }
  }

  static Future<void> clearAllAppCache() async {
    _ensuredThumbDirs.clear();
    try {
      final root = await _getAppCacheRoot();
      final dir = Directory('$root/thumbs');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _memoryCache.clear();
    _latestKeyByFile.clear();
    _sizeCache.clear();
  }

  static Future<void> invalidateFile(
    MountedContainer container,
    String filePath, {
    List<ThumbnailQuality> qualities = const [ThumbnailQuality.defaultQuality],
  }) async {
    final prefix =
        '${container.volId}:${container.mountedAt.millisecondsSinceEpoch}:$filePath|';
    _memoryCache.removeWhere((key) => key.startsWith(prefix));
    _sizeCache.removeWhere((key, _) => key.startsWith(prefix));
    _latestKeyByFile.remove(prefix);

    final dir = await _thumbDir(container);
    for (final quality in qualities) {
      try {
        final cacheKey = await _encodeKey(_qualifiedPath(filePath, quality));
        final file = File('$dir/$cacheKey');
        if (await file.exists()) await file.delete();
        final metaFile = File('${file.path}.meta');
        if (await metaFile.exists()) await metaFile.delete();
        final baseKey = await _encodeKey(filePath);
        final baseFile = File('$dir/$baseKey');
        if (await baseFile.exists()) await baseFile.delete();
      } catch (_) {}

      try {
        final key = await _encodeKey(_qualifiedPath(filePath, quality));
        final uriStr = container.uri.toString();
        final index = _inContainerIndices[uriStr];
        if (index != null && index.entries.containsKey(key)) {
          index.entries.remove(key);
          await _fileIo.writeWholeFile(
            container,
            inContainerIndexFile,
            _serializeIndex(index),
          );
        }
        await _fileIo.deleteFile(container, '$inContainerDir/$key');
      } catch (_) {}
    }
  }

  // ── Budget Enforcement ─────────────────────────────────────────────────────

  static const int defaultMaxAppCacheBytes = 100 * 1024 * 1024;
  static int _putWriteCount = 0;

  static Future<void> enforceDiskBudget([
    int maxBytes = defaultMaxAppCacheBytes,
  ]) async {
    try {
      final rootPath = await _getAppCacheRoot();
      final root = Directory('$rootPath/thumbs');
      if (!await root.exists()) return;

      final files = <({File file, int size, DateTime modified})>[];
      var totalBytes = 0;

      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.tmp')) continue;
        try {
          final stat = await entity.stat();
          files.add((file: entity, size: stat.size, modified: stat.modified));
          totalBytes += stat.size;
        } catch (_) {}
      }

      if (totalBytes <= maxBytes) return;

      final targetBytes = (maxBytes * 0.8).toInt();
      files.sort((a, b) => a.modified.compareTo(b.modified));

      for (final entry in files) {
        if (totalBytes <= targetBytes) break;
        try {
          await entry.file.delete();
          totalBytes -= entry.size;
        } catch (_) {}
      }
    } catch (e) {
      VeLog.e('ThumbnailCacheService', 'App-cache disk budget eviction failed', e);
    }
  }

  static const int defaultMaxInContainerCacheBytes = 50 * 1024 * 1024;
  static int _inContainerPutWriteCount = 0;

  static Future<void> enforceInContainerDiskBudget(
    MountedContainer container, [
    int maxBytes = defaultMaxInContainerCacheBytes,
  ]) async {
    try {
      final totalBytes = await _fileIo.getFolderSize(container, inContainerDir);
      if (totalBytes <= maxBytes) return;

      final rawEntries = await _fileIo.listDirectory(container, inContainerDir);
      if (rawEntries == null || rawEntries.isEmpty) return;

      final packEntries = rawEntries
          .where((raw) => !raw.startsWith('System:'))
          .map(RawEntry.parse)
          .where((e) => !e.isDir && e.name.startsWith('pack_') && e.name.endsWith('.bin'))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      final targetBytes = (maxBytes * 0.8).toInt();
      var runningBytes = totalBytes;
      final deletedPackIds = <int>{};

      for (final entry in packEntries) {
        if (runningBytes <= targetBytes) break;
        final deleted = await _fileIo.deleteFile(
          container,
          '$inContainerDir/${entry.name}',
        );
        if (deleted) {
          runningBytes -= entry.sizeBytes;
          final idStr = entry.name.replaceAll('pack_', '').replaceAll('.bin', '');
          final packId = int.tryParse(idStr);
          if (packId != null) deletedPackIds.add(packId);
        }
      }

      if (deletedPackIds.isNotEmpty) {
        final uriStr = container.uri.toString();
        var index = _inContainerIndices[uriStr];
        index ??= await _loadInContainerIndex(container);
        index.entries.removeWhere((_, e) => deletedPackIds.contains(e.packId));
        await _fileIo.writeWholeFile(
          container,
          inContainerIndexFile,
          _serializeIndex(index),
        );
      }
    } catch (e) {
      VeLog.e('ThumbnailCacheService', 'In-container disk budget eviction failed', e);
    }
  }

  static Future<void> pruneStaleAppCache(Set<String> activeContainerUris) async {
    try {
      final rootPath = await _getAppCacheRoot();
      final root = Directory('$rootPath/thumbs');
      if (!await root.exists()) return;
      final activeKeys = <String>{};
      for (final uri in activeContainerUris) {
        activeKeys.add(await _encodeKey(uri));
      }
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final dirName = e.path.split('/').last;
        if (!activeKeys.contains(dirName)) {
          _ensuredThumbDirs.removeWhere((key, _) => key.contains(dirName));
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  // ── Dimension Parsers ──────────────────────────────────────────────────────

  static (int width, int height)? _extractImageDimensions(Uint8List bytes) {
    if (_isPng(bytes)) return _extractPngDimensions(bytes);
    if (_isWebp(bytes)) return _extractWebpDimensions(bytes);
    return _extractJpegDimensions(bytes);
  }

  static (int width, int height)? _extractPngDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;
    final width =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    if (width <= 0 || height <= 0) return null;
    return (width, height);
  }

  static (int width, int height)? _extractWebpDimensions(Uint8List bytes) {
    if (bytes.length < 30) return null;
    final fourCc = String.fromCharCodes(bytes.sublist(12, 16));
    switch (fourCc) {
      case 'VP8 ':
        final width = ((bytes[27] << 8) | bytes[26]) & 0x3FFF;
        final height = ((bytes[29] << 8) | bytes[28]) & 0x3FFF;
        return (width > 0 && height > 0) ? (width, height) : null;
      case 'VP8L':
        final bits =
            bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
        final width = (bits & 0x3FFF) + 1;
        final height = ((bits >> 14) & 0x3FFF) + 1;
        return (width, height);
      case 'VP8X':
        final width =
            ((bytes[24] << 16) | (bytes[25] << 8) | bytes[26]) + 1;
        final height =
            ((bytes[27] << 16) | (bytes[28] << 8) | bytes[29]) + 1;
        return (width, height);
      default:
        return null;
    }
  }

  static (int width, int height)? _extractJpegDimensions(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    var offset = 2;
    while (offset < bytes.length - 8) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      if (marker == 0xFF || marker == 0x00) {
        offset++;
        continue;
      }
      if (marker == 0xD8 ||
          marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if ((marker >= 0xC0 && marker <= 0xC3) ||
          (marker >= 0xC5 && marker <= 0xC7) ||
          (marker >= 0xC9 && marker <= 0xCB) ||
          (marker >= 0xCD && marker <= 0xCF)) {
        if (offset + 8 < bytes.length) {
          final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
          final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
          if (width > 0 && height > 0) return (width, height);
        }
        return null;
      }
      if (offset + 3 >= bytes.length) break;
      final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2) break;
      offset += 2 + length;
    }
    return null;
  }

  static bool _looksLikeValidImage(Uint8List bytes) {
    if (_isPng(bytes)) return _looksLikeValidPng(bytes);
    if (_isWebp(bytes)) return _looksLikeValidWebp(bytes);
    return _looksLikeValidJpeg(bytes);
  }

  static bool _looksLikeValidJpeg(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return false;
    final len = bytes.length;
    return bytes[len - 2] == 0xFF && bytes[len - 1] == 0xD9;
  }

  static const _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

  static bool _isPng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  static bool _looksLikeValidPng(Uint8List bytes) {
    if (bytes.length < 20) return false;
    final len = bytes.length;
    return bytes[len - 8] == 0x49 &&
        bytes[len - 7] == 0x45 &&
        bytes[len - 6] == 0x4E &&
        bytes[len - 5] == 0x44;
  }

  static bool _isWebp(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  }

  static bool _looksLikeValidWebp(Uint8List bytes) {
    if (bytes.length < 16) return false;
    final riffLength =
        bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
    if (riffLength <= 0) return false;
    return bytes.length >= riffLength + 8;
  }

  static final Map<String, Future<void>> _ensuredThumbDirs = {};
  static final Map<String, Future<void>> _inFlightPuts = {};
}

// ── In-Container Pack Models & Coalescing Queue ─────────────────────────────

class _PackEntry {
  final int packId;
  final int offset;
  final int length;
  final int width;
  final int height;

  const _PackEntry({
    required this.packId,
    required this.offset,
    required this.length,
    required this.width,
    required this.height,
  });
}

class _InContainerPackIndex {
  int nextPackId;
  final Map<String, _PackEntry> entries;

  _InContainerPackIndex({
    required this.nextPackId,
    required this.entries,
  });
}

class _PendingPackThumb {
  final String keyHex;
  final Uint8List data;
  final int width;
  final int height;
  Completer<void>? completer;

  _PendingPackThumb({
    required this.keyHex,
    required this.data,
    required this.width,
    required this.height,
  });
}

class _InContainerPackQueue {
  final MountedContainer container;
  final Map<String, _PendingPackThumb> _pending = {};
  Timer? _debounceTimer;
  bool _isFlushing = false;

  static const int _maxPendingItems = 40;

  _InContainerPackQueue(this.container);

  void dispose() {
    _debounceTimer?.cancel();
    _pending.clear();
  }

  _PendingPackThumb? getPending(String keyHex) => _pending[keyHex];

  Future<void> flushNow([VaultFileIoApi? fileIo]) =>
      _drain(fileIo ?? ThumbnailCacheService._fileIo);

  Future<void> enqueue(
    _PendingPackThumb thumb,
    VaultFileIoApi fileIo,
  ) {
    final completer = Completer<void>();
    thumb.completer = completer;
    _pending[thumb.keyHex] = thumb;

    _debounceTimer?.cancel();
    if (_pending.length >= _maxPendingItems) {
      unawaited(_drain(fileIo));
    } else {
      _debounceTimer = Timer(ThumbnailCacheService.inContainerDebounceDuration, () {
        unawaited(_drain(fileIo));
      });
    }
    return completer.future;
  }

  Future<void> _drain(VaultFileIoApi fileIo) async {
    if (_isFlushing || _pending.isEmpty) return;
    _isFlushing = true;
    _debounceTimer?.cancel();

    try {
      while (_pending.isNotEmpty) {
        final batch = _pending.values.toList();
        _pending.clear();

        try {
          await _commitBatch(batch, fileIo);
          for (final item in batch) {
            if (item.completer != null && !item.completer!.isCompleted) {
              item.completer!.complete();
            }
          }
        } catch (e) {
          for (final item in batch) {
            if (item.completer != null && !item.completer!.isCompleted) {
              item.completer!.completeError(e);
            }
          }
        }
      }
    } finally {
      _isFlushing = false;
    }
  }

  Future<void> _commitBatch(
    List<_PendingPackThumb> batch,
    VaultFileIoApi fileIo,
  ) async {
    final uriStr = container.uri.toString();
    if (!ThumbnailCacheService._ensuredThumbDirs.containsKey(uriStr)) {
      ThumbnailCacheService._ensuredThumbDirs[uriStr] = fileIo.createDirectory(
        container,
        ThumbnailCacheService.inContainerDir,
      );
    }
    await ThumbnailCacheService._ensuredThumbDirs[uriStr];

    var index = ThumbnailCacheService._inContainerIndices[uriStr];
    index ??= await ThumbnailCacheService._loadInContainerIndex(container);
    ThumbnailCacheService._inContainerIndices[uriStr] = index;

    final currentPackId = index.nextPackId;
    index.nextPackId++;

    final packFileName =
        'pack_${currentPackId.toString().padLeft(4, '0')}.bin';
    final packPath = '${ThumbnailCacheService.inContainerDir}/$packFileName';

    final builder = BytesBuilder(copy: false);
    var currentOffset = 0;

    for (final item in batch) {
      builder.add(item.data);
      index.entries[item.keyHex] = _PackEntry(
        packId: currentPackId,
        offset: currentOffset,
        length: item.data.length,
        width: item.width,
        height: item.height,
      );
      currentOffset += item.data.length;
    }

    final packBytes = builder.takeBytes();

    // 1. Write the new immutable pack segment file
    await fileIo.writeWholeFile(container, packPath, packBytes);

    // 2. Commit updated binary index
    final serializedIndex = ThumbnailCacheService._serializeIndex(index);
    await fileIo.writeWholeFile(
      container,
      ThumbnailCacheService.inContainerIndexFile,
      serializedIndex,
    );
  }
}