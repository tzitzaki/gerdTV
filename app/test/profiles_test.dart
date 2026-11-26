// New, because nothing owns which profile opens at start: one opens by itself, several show the picker with the last
// one used first, "Always open this one" skips the picker, and a profile that can't open falls back to the picker.
// Also the provider edit (a new login replaces the old one only once it works) and Skip (a profile without provider:
// only Settings shows).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/shell.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';

import 'support/fake_core.dart';

/// No stored secrets: opening any Xtream Codes profile fails, which is what the fallbacks need.
class _Library extends Fake implements Library {}

class NoSecrets extends Secrets {
  @override
  Future<List<String>?> read(String profileId) async => null;

  /// What was written, by profile id (nothing reaches real secure storage).
  final written = <String, List<String>>{};

  @override
  Future<void> write(String profileId, List<String> secrets) async =>
      written[profileId] = secrets;
}

ProfileInfo profile(String id) => ProfileInfo(
  id: id,
  name: 'Provider $id',
  source: SourceKind.xtream,
  server: 'http://$id.example.invalid',
  userAgent: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // start() sends the logo to the platform channel
  late FakeCore core;
  setUpAll(() => core = useFakeCore());
  setUp(() => core.appSettings.clear());

  Future<Session> start(List<ProfileInfo> profiles) async {
    core.profiles = profiles;
    final s = Session(secrets: NoSecrets(), appDir: '/nonexistent');
    await s.start();
    return s;
  }

  test('several profiles: the picker, the last one used first', () async {
    core.appSettings[Session.settingLastProfile] = 'b';
    final s = await start([profile('a'), profile('b'), profile('c')]);
    expect(s.state, SessionState.choosing);
    expect(s.profiles.map((p) => p.id), ['b', 'a', 'c']);
  });

  test('"always" pointing at one that cannot open: the picker again', () async {
    core.appSettings[Session.settingAlwaysProfile] = 'a';
    final s = await start([profile('a'), profile('b')]);
    expect(s.state, SessionState.choosing);
  });

  test('edit: a refused login saves nothing, the old one stays', () async {
    final s = await start([profile('a')]);
    core.loginError = 'the server rejected the login';
    final error = await s.updateProfile(profile('a'), ['new', 'wrong']);
    expect(error, 'the server rejected the login');
    expect(core.saved, isEmpty);
    expect((s.secrets as NoSecrets).written, isEmpty);
    core.loginError = null;
  });

  test('skip: a profile without provider opens, only Settings shows', () async {
    final s = await start([]);
    expect(s.state, SessionState.needsSetup);
    core.openLibrary = _Library.new;
    await s.skipSetup('No provider yet');
    core.openLibrary = null;
    expect(s.state, SessionState.ready);
    expect(s.hasProvider, isFalse);
    expect(core.saved.last.source, SourceKind.none);
    expect(shellPages(provider: s.hasProvider, premiumize: false), [
      ShellPage.settings,
    ]);
    expect(shellPages(provider: false, premiumize: true), [
      ShellPage.premiumize,
      ShellPage.settings,
    ]);
  });

  test('a single profile that cannot open: setup', () async {
    final s = await start([profile('a')]);
    expect(s.state, SessionState.needsSetup);
  });
}
