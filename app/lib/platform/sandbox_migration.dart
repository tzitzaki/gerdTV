// macOS without the sandbox (owner decision, for the in-app updater): sandboxed builds kept their data in the app's
// container (~/Library/Containers/<id>/Data/Library/Application Support/<id>), unsandboxed ones use
// ~/Library/Application Support/<id>. On the first start without the sandbox the container's data is copied over,
// never moved: the container stays as the backup (CLAUDE.md: a backup before anything hard to undo).
// Debugging: "sandbox-migration: copied N files" in the log; the container is left untouched either way.

import 'dart:io';

/// Copies [from] into [to] when [to] has no profiles yet and [from] has; returns how many files were copied.
int migrateSandboxData(Directory from, Directory to) {
  if (File('${to.path}/profiles.json').existsSync()) {
    return 0; // already migrated, or set up fresh
  }
  if (!File('${from.path}/profiles.json').existsSync()) {
    return 0; // nothing to carry over
  }
  var copied = 0;
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final target = '${to.path}${entity.path.substring(from.path.length)}';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
      copied++;
    }
  }
  return copied;
}

/// The sandboxed container's Application Support folder for [bundleId] under [home].
Directory sandboxSupportDir(String home, String bundleId) => Directory(
  '$home/Library/Containers/$bundleId/Data/Library/Application Support/$bundleId',
);
