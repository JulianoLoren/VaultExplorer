import 'dart:io';

void main() {
  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    print('Error: Run this script from the project root directory.');
    exit(1);
  }

  // 1. Extract version and base build number from pubspec.yaml
  final pubspecContent = pubspecFile.readAsStringSync();
  final versionMatch = RegExp(r'^version:\s*([^+]+)\+(\d+)', multiLine: true).firstMatch(pubspecContent);

  if (versionMatch == null) {
    print('Error: Could not parse "version: x.y.z+number" from pubspec.yaml');
    exit(1);
  }

  final versionName = versionMatch.group(1)!.trim();
  final baseCode = int.parse(versionMatch.group(2)!.trim());

  print('=== Preparing Release v$versionName (Base code: $baseCode) ===');

  // The 3 architecture offsets matching GitHub Actions and F-Droid
  final offsets = [1, 2, 3];
  final generatedCodes = offsets.map((o) => baseCode * 100 + o).toList();

  final metadataDir = Directory('fastlane/metadata/android');
  if (!metadataDir.existsSync()) {
    print('Error: fastlane/metadata/android directory not found.');
    exit(1);
  }

  int createdCount = 0;

  // 2. Iterate through all locale directories (e.g., en-US, de-DE, etc.)
  for (final localeDir in metadataDir.listSync().whereType<Directory>()) {
    final changelogsDir = Directory('${localeDir.path}/changelogs');
    if (!changelogsDir.existsSync()) continue;

    final baseChangelog = File('${changelogsDir.path}/$baseCode.txt');
    if (!baseChangelog.existsSync()) {
      continue;
    }

    final changelogContent = baseChangelog.readAsStringSync();

    // 3. Replicate base changelog to 3801.txt, 3802.txt, 3803.txt
    for (final code in generatedCodes) {
      final targetFile = File('${changelogsDir.path}/$code.txt');
      targetFile.writeAsStringSync(changelogContent);
      createdCount++;
    }

    print('Updated changelogs for locale: ${localeDir.uri.pathSegments.reversed.elementAt(1)}');
  }

  if (createdCount == 0) {
    print('\nWarning: No "$baseCode.txt" found in fastlane/metadata/android/<locale>/changelogs/.');
    print('Create "$baseCode.txt" first, then run this script again.');
    exit(1);
  }

  print('\nSuccessfully generated $createdCount changelog files for F-Droid ($generatedCodes).');
  print('\nReady to release! Run:');
  print('  git add .');
  print('  git commit -m "Release v$versionName"');
  print('  git tag v$versionName');
  print('  git push origin main --tags');
}