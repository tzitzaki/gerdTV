// New, because nothing owned the macOS update swap: it waits until gerdTV has quit, installs the new bundle, and
// puts the old one back when copying fails; extended: the download is deleted once installed, kept after a failure.
// Run on any platform with cp standing in for ditto.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<(Directory, String)> setUp(String version) async {
  final root = Directory.systemTemp.createTempSync('gerdtv-swap');
  for (final (name, v) in [
    ('Applications/gerdTV.app', 'v1'),
    ('new/gerdTV.app', version),
  ]) {
    File('${root.path}/$name/Contents/version').createSync(recursive: true);
    File('${root.path}/$name/Contents/version').writeAsStringSync(v);
  }
  File('${root.path}/Downloads/gerdTV-macos.zip').createSync(recursive: true);
  File(
    '${root.path}/swap-macos.sh',
  ).writeAsStringSync(File('assets/update/swap-macos.sh').readAsStringSync());
  return (root, '${root.path}/Applications/gerdTV.app');
}

Future<int> swap(Directory root, String old, {required String copy}) async {
  // A stand-in for gerdTV that quits after 2 s: the swap must wait for it.
  final app = await Process.start('sleep', ['2']);
  final r = await Process.run(
    'bash',
    [
      '${root.path}/swap-macos.sh',
      '${app.pid}',
      old,
      '${root.path}/new/gerdTV.app',
      '${root.path}/Downloads/gerdTV-macos.zip',
    ],
    environment: {'GERDTV_COPY': copy, 'GERDTV_OPEN': 'true'},
  );
  return r.exitCode;
}

void main() {
  test(
    'the new bundle replaces the installed one once gerdTV has quit',
    () async {
      final (root, old) = await setUp('v2');
      addTearDown(() => root.deleteSync(recursive: true));
      final started = DateTime.now();
      expect(await swap(root, old, copy: 'cp -R'), 0);
      expect(
        DateTime.now().difference(started).inMilliseconds,
        greaterThan(1500),
        reason: 'waited for the app',
      );
      expect(File('$old/Contents/version').readAsStringSync(), 'v2');
      expect(
        Directory('${root.path}/Applications/gerdTV.previous.app').existsSync(),
        isFalse,
      );
      expect(
        File('${root.path}/swap.log').readAsStringSync(),
        contains('installed'),
      );
      expect(
        File('${root.path}/Downloads/gerdTV-macos.zip').existsSync(),
        isFalse,
        reason: 'the download is deleted',
      );
      expect(Directory('${root.path}/new/gerdTV.app').existsSync(), isFalse);
    },
  );

  test('a failed copy puts the previous version back', () async {
    final (root, old) = await setUp('v2');
    addTearDown(() => root.deleteSync(recursive: true));
    await swap(root, old, copy: 'false');
    expect(File('$old/Contents/version').readAsStringSync(), 'v1');
    expect(
      File('${root.path}/swap.log').readAsStringSync(),
      contains('previous version is back'),
    );
    expect(
      File('${root.path}/Downloads/gerdTV-macos.zip').existsSync(),
      isTrue,
      reason: 'kept for another try',
    );
  });
}
