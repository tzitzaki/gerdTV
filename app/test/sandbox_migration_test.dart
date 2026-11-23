// New, because nothing owned the move off the macOS sandbox: the container's data is copied (never moved) once,
// only when the new place has no profiles yet.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/sandbox_migration.dart';

void main() {
  test('sandboxed data is copied once, the container stays as the backup', () {
    final root = Directory.systemTemp.createTempSync('gerdtv-sandbox');
    addTearDown(() => root.deleteSync(recursive: true));
    final from = sandboxSupportDir(root.path, 'world.zakis.gerdtv');
    final to = Directory(
      '${root.path}/Library/Application Support/world.zakis.gerdtv',
    );
    // Nothing in the container: nothing happens.
    expect(migrateSandboxData(from, to), 0);
    File('${from.path}/profiles.json').createSync(recursive: true);
    File('${from.path}/profiles.json').writeAsStringSync('[{"id":"p1"}]');
    File('${from.path}/profiles/p1.db').createSync(recursive: true);
    // First start without the sandbox: both files arrive, the originals stay.
    expect(migrateSandboxData(from, to), 2);
    expect(
      File('${to.path}/profiles.json').readAsStringSync(),
      '[{"id":"p1"}]',
    );
    expect(File('${to.path}/profiles/p1.db').existsSync(), isTrue);
    expect(
      File('${from.path}/profiles.json').existsSync(),
      isTrue,
      reason: 'the container is the backup',
    );
    // Later starts: the new place has profiles, nothing is copied over them.
    File('${to.path}/profiles.json').writeAsStringSync('[{"id":"p2"}]');
    expect(migrateSandboxData(from, to), 0);
    expect(
      File('${to.path}/profiles.json').readAsStringSync(),
      '[{"id":"p2"}]',
    );
  });
}
