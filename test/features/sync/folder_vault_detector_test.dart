import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultexplorer/core/api/vault_file_io_api.dart';
import 'package:vaultexplorer/core/filesystem/local_storage_container.dart';
import 'package:vaultexplorer/data/models/container_format.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/features/sync/domain/folder_vault_detector.dart';

/// Answers [VaultFileIoApi.listDirectory] from a fixed map of
/// container-relative folder -> raw wire-format entries (see `RawEntry`).
/// A folder that isn't in the map lists as null, like a missing folder;
/// folders in [throwing] raise instead, like a dead SAF grant.
class _FakeListingApi extends VaultFileIoApi {
  final Map<String, List<String>> listings;
  final Set<String> throwing;
  final List<String> requested = [];

  _FakeListingApi(this.listings, {this.throwing = const {}})
    : super(const MethodChannel('test'));

  @override
  Future<List<String>?> listDirectory(
    MountedContainer container,
    String dirPath, {
    bool refresh = false,
  }) async {
    requested.add(dirPath);
    if (throwing.contains(dirPath)) throw PlatformException(code: 'boom');
    return listings[dirPath];
  }
}

MountedContainer _plainFolder() => buildExternalStorageContainer(
  rootPath: '/storage/emulated/0',
  displayName: 'Device',
  volId: -1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('folderVaultFormatFromNames', () {
    test('recognises the marker file of each folder-vault format', () {
      expect(
        folderVaultFormatFromNames(['gocryptfs.diriv', 'gocryptfs.conf']),
        ContainerFormat.gocryptfs,
      );
      expect(
        folderVaultFormatFromNames(['cryfs.config', 'ab']),
        ContainerFormat.cryfs,
      );
      expect(
        folderVaultFormatFromNames(['vault.cryptomator', 'd']),
        ContainerFormat.cryptomator,
      );
      // Cryptomator formats 6/7 have only the masterkey file.
      expect(
        folderVaultFormatFromNames(['masterkey.cryptomator']),
        ContainerFormat.cryptomator,
      );
    });

    test('matches case-insensitively', () {
      expect(
        folderVaultFormatFromNames(['GoCryptFS.CONF']),
        ContainerFormat.gocryptfs,
      );
    });

    test('ordinary files are not markers', () {
      expect(
        folderVaultFormatFromNames([
          'notes.txt',
          'photo.jpg',
          'gocryptfs.conf.bak',
          'my-cryfs.config',
        ]),
        isNull,
      );
      expect(folderVaultFormatFromNames(const []), isNull);
    });
  });

  group('findFolderVaultAlong', () {
    test('finds a vault whose storage folder is the container root', () async {
      final api = _FakeListingApi({
        '': ['F|300|1000|gocryptfs.conf', 'F|16|1000|gocryptfs.diriv'],
      });

      final hit = await findFolderVaultAlong(api, _plainFolder(), '');

      expect(hit, isNotNull);
      expect(hit!.format, ContainerFormat.gocryptfs);
      expect(hit.isContainerRoot, isTrue);
    });

    test('finds a vault when the chosen folder is the vault folder itself', () async {
      final api = _FakeListingApi({
        '': ['D|0|1000|Vaults', 'F|10|1000|readme.txt'],
        'Vaults': ['D|0|1000|work'],
        'Vaults/work': ['F|900|1000|vault.cryptomator', 'D|0|1000|d'],
      });

      final hit = await findFolderVaultAlong(api, _plainFolder(), 'Vaults/work');

      expect(hit, isNotNull);
      expect(hit!.format, ContainerFormat.cryptomator);
      expect(hit.path, 'Vaults/work');
      expect(hit.isContainerRoot, isFalse);
    });

    test('finds a vault above the chosen folder (a folder inside its storage)', () async {
      final api = _FakeListingApi({
        '': ['D|0|1000|Vaults'],
        'Vaults': ['D|0|1000|work'],
        'Vaults/work': ['F|400|1000|cryfs.config', 'D|0|1000|ab'],
        'Vaults/work/ab': ['D|0|1000|cd'],
      });

      final hit = await findFolderVaultAlong(
        api,
        _plainFolder(),
        'Vaults/work/ab',
      );

      expect(hit, isNotNull);
      expect(hit!.format, ContainerFormat.cryfs);
      expect(hit.path, 'Vaults/work');
    });

    test('a plain folder is not a vault', () async {
      final api = _FakeListingApi({
        '': ['D|0|1000|Documents'],
        'Documents': ['F|10|1000|a.txt', 'D|0|1000|Notes'],
        'Documents/Notes': ['F|10|1000|b.txt'],
      });

      expect(
        await findFolderVaultAlong(api, _plainFolder(), 'Documents/Notes'),
        isNull,
      );
      // Every level from the root down to the chosen folder was checked.
      expect(api.requested, ['', 'Documents', 'Documents/Notes']);
    });

    test('only looks at the chosen folder and above, never below it', () async {
      final api = _FakeListingApi({
        '': ['D|0|1000|Backups'],
        // A vault *inside* the chosen folder doesn't make the folder itself
        // a vault: its own files are ordinary.
        'Backups': ['D|0|1000|old-vault', 'F|10|1000|note.txt'],
        'Backups/old-vault': ['F|300|1000|gocryptfs.conf'],
      });

      expect(await findFolderVaultAlong(api, _plainFolder(), 'Backups'), isNull);
      expect(api.requested, isNot(contains('Backups/old-vault')));
    });

    test('a folder that merely has a marker name is not a marker file', () async {
      final api = _FakeListingApi({
        '': ['D|0|1000|gocryptfs.conf'],
      });

      expect(await findFolderVaultAlong(api, _plainFolder(), ''), isNull);
    });

    test('unreadable folders are skipped, not reported as vaults', () async {
      final api = _FakeListingApi(
        {
          'a': ['F|10|1000|x.txt'],
        },
        throwing: {''},
      );

      expect(await findFolderVaultAlong(api, _plainFolder(), 'a'), isNull);
      expect(api.requested, ['', 'a']);
    });

    test('a vault further down the path is still found past an unreadable level', () async {
      final api = _FakeListingApi(
        {
          'a': ['F|300|1000|gocryptfs.conf'],
          'a/b': ['F|10|1000|x.txt'],
        },
        throwing: {''},
      );

      final hit = await findFolderVaultAlong(api, _plainFolder(), 'a/b');

      expect(hit, isNotNull);
      expect(hit!.path, 'a');
    });

    test('a malformed listing counts as unreadable instead of throwing', () async {
      final api = _FakeListingApi({
        '': ['this is not a wire entry'],
        'a': ['F|300|1000|gocryptfs.conf'],
      });

      final hit = await findFolderVaultAlong(api, _plainFolder(), 'a');

      expect(hit, isNotNull);
      expect(hit!.path, 'a');
    });

    test('normalises slashes in the sub path', () async {
      final api = _FakeListingApi({
        '': const [],
        'a': ['F|300|1000|masterkey.cryptomator'],
      });

      final hit = await findFolderVaultAlong(api, _plainFolder(), '/a//');

      expect(hit, isNotNull);
      expect(hit!.path, 'a');
    });
  });
}
