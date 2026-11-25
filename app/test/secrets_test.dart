// Secrets on macOS: kept through Apple's security tool (lib/platform/mac_keychain.dart), moved there once from the
// old place (flutter_secure_storage), and a value is never lost or left behind on the way.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/mac_keychain.dart';
import 'package:gerdtv/services/secrets.dart';

/// The security tool: items by account, the arguments of every call, and switches for what can go wrong.
class FakeSecurity {
  final items = <String, String>{};
  final args = <String>[];
  bool writesFail = false; // `security -i` reports nothing useful, so a lost write only shows when read back
  int? readExit; // e.g. 36: the keychain is locked

  Future<({int exitCode, String stdout})> run(
    List<String> a, {
    String? stdin,
  }) async {
    args.addAll(a);
    if (stdin != null) {
      final m = RegExp(r'-a "(.+?)" -w "(.+?)"\n$').firstMatch(stdin)!;
      if (!writesFail) items[m[1]!] = m[2]!;
      return (exitCode: 0, stdout: '');
    }
    final account = a[a.indexOf('-a') + 1];
    if (a.first == 'delete-generic-password') {
      return (exitCode: items.remove(account) == null ? 44 : 0, stdout: '');
    }
    if (readExit != null) return (exitCode: readExit!, stdout: '');
    final v = items[account];
    return v == null
        ? (exitCode: 44, stdout: '')
        : (exitCode: 0, stdout: '$v\n');
  }
}

/// The old place, counting reads (each one is a prompt after an update); [denied]: the user clicked Deny.
class OldStorage extends Fake implements FlutterSecureStorage {
  final items = <String, String>{};
  int reads = 0;
  bool denied = false;
  bool deleteFails = false;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String;
    switch (i.memberName) {
      case #read:
        reads++;
        return denied
            ? Future<String?>.error(StateError('denied'))
            : Future<String?>.value(items[key]);
      case #delete:
        if (deleteFails) return Future<void>.error(StateError('denied'));
        items.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

void main() {
  const key = 'gerdtv.profile.p1';
  const login = ['user', 'p"ä\\ss'];
  late FakeSecurity tool;
  late OldStorage old;
  late Secrets secrets;
  setUp(() {
    tool = FakeSecurity();
    old = OldStorage()..items[key] = jsonEncode(login);
    secrets = Secrets(old, MacKeychain(run: tool.run));
  });

  test(
    'a login moves once and is read without the old place after that',
    () async {
      expect(await secrets.read('p1'), login);
      expect(old.items, isEmpty);
      expect(tool.items.keys, [key]);
      expect(await secrets.read('p1'), login);
      expect(old.reads, 1);
      // The process list shows arguments to everyone: neither the value nor its encoded form may be there.
      expect(tool.args.join(' '), isNot(contains(tool.items[key]!)));
      expect(tool.args.join(' '), isNot(contains('ä')));
    },
  );

  test('what goes wrong while moving never loses the login', () async {
    tool.writesFail = true;
    expect(
      await secrets.read('p1'),
      login,
      reason: 'usable although not moved',
    );
    expect(old.items, contains(key));

    tool.writesFail = false;
    old.denied = true;
    expect(await secrets.read('p1'), isNull);
    expect(old.items, contains(key));
    expect(tool.items, isEmpty);

    old.denied = false;
    old.deleteFails = true;
    expect(await secrets.read('p1'), login);
    expect(await secrets.read('p1'), login);
    expect(
      tool.items,
      contains(key),
      reason: 'the new item wins over the leftover',
    );
  });

  test(
    'a locked keychain is not a missing item: the old place stays untouched',
    () async {
      tool.readExit = 36;
      expect(await secrets.read('p1'), isNull);
      expect(old.reads, 0);
    },
  );

  test('writing and deleting leave nothing in the old place', () async {
    await secrets.write('p1', ['new']);
    expect(old.items, isEmpty);
    expect(await secrets.read('p1'), ['new']);

    old.items[key] = jsonEncode(login);
    await secrets.delete('p1');
    expect(await secrets.read('p1'), isNull);

    await secrets.writeService('p1', 'trakt', 'token');
    expect(await secrets.readService('p1', 'trakt'), 'token');
    await secrets.writeService('p1', 'trakt', null);
    expect(await secrets.readService('p1', 'trakt'), isNull);
  });

  test(
    'a value too long for the tool is refused before it overwrites',
    () async {
      await secrets.write('p1', ['good']);
      await expectLater(secrets.write('p1', ['x' * 4000]), throwsStateError);
      expect(await secrets.read('p1'), ['good']);
    },
  );
}
