import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/data/models/container_format.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/sync/domain/models/sync_rule.dart';

/// Files that sit at the root of a folder vault's storage directory and
/// give the format away. Compared case-insensitively (FAT-formatted SD
/// cards keep the case but don't distinguish it).
const Map<String, ContainerFormat> _folderVaultMarkers = {
  'gocryptfs.conf': ContainerFormat.gocryptfs,
  'cryfs.config': ContainerFormat.cryfs,
  // Cryptomator vault format 8 keeps its settings in `vault.cryptomator`;
  // formats 6/7 only have the masterkey file.
  'vault.cryptomator': ContainerFormat.cryptomator,
  'masterkey.cryptomator': ContainerFormat.cryptomator,
};

/// Which folder-vault format do the file names of one directory belong
/// to, or null when none of them is a vault marker.
ContainerFormat? folderVaultFormatFromNames(Iterable<String> fileNames) {
  for (final name in fileNames) {
    final format = _folderVaultMarkers[name.toLowerCase()];
    if (format != null) return format;
  }
  return null;
}

/// A folder vault's storage directory found on a plain (unmounted) storage.
class FolderVaultHit {
  final ContainerFormat format;

  /// The folder that holds the marker, relative to the container root
  /// (`''` = the container root itself).
  final String path;

  const FolderVaultHit(this.format, this.path);

  /// The container root itself is the vault's storage folder -- as opposed
  /// to a folder further down the chosen path.
  bool get isContainerRoot => path.isEmpty;

  @override
  String toString() => 'FolderVaultHit(${format.wire} at "$path")';
}

/// Checks whether [subPath] inside [container], or any folder above it up
/// to the container root, is the storage directory of a folder vault
/// (gocryptfs / Cryptomator / CryFS).
///
/// Sync must never treat such a folder as plain storage. Its content is
/// ciphertext: reading it as a target pulls *encrypted* files into the
/// source vault as if they were documents, and writing to it drops
/// *plaintext* files into the middle of someone else's vault. The only
/// valid way to sync with a vault is through its unlocked (mounted) view,
/// where the engine encrypts and decrypts.
///
/// Folders that can't be listed are skipped rather than treated as a hit:
/// an unreadable target is already skipped by the sync scan.
Future<FolderVaultHit?> findFolderVaultAlong(
  VaultFileIoApi io,
  MountedContainer container,
  String subPath,
) async {
  final segments = normalizeSyncPath(subPath)
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();

  var current = '';
  for (var depth = 0; depth <= segments.length; depth++) {
    if (depth > 0) {
      final segment = segments[depth - 1];
      current = current.isEmpty ? segment : '$current/$segment';
    }

    // Parsing sits inside the try as well: RawEntry.parse throws on a
    // malformed line, and an odd listing must read as "unreadable" here
    // rather than take the caller down.
    List<String>? fileNames;
    try {
      final raw = await io.listDirectory(container, current, refresh: true);
      if (raw != null) {
        fileNames = RawEntry.parseAll(raw)
            .where((e) => !e.isDir && !e.isPlaceholder)
            .map((e) => e.name)
            .toList();
      }
    } catch (_) {
      fileNames = null;
    }
    if (fileNames == null) continue;

    final format = folderVaultFormatFromNames(fileNames);
    if (format != null) return FolderVaultHit(format, current);
  }
  return null;
}
