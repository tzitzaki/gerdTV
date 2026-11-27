// New, because nothing owns which profile opens at start: one opens by itself, several show the picker with the last
// one used first, "Always open this one" skips the picker, and a profile that can't open falls back to the picker.
// Also the provider edit (a new login replaces the old one only once it works), Skip (a profile without provider:
// only Settings shows) and what a device sync does to the open profile (the placeholder gives way, a changed profile
// reopens).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/shell.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';

import 'support/fake_core.dart';

/// No stored secrets: opening any Xtream Codes profile fails, which is what the fallbacks need.
class _Library extends Fake implements Library {}

class NoSecrets extends Secrets {
  /// Every login read, by profile id (openProfile reads it first).
  final reads = <String>[];

  /// Linked services' tokens, as "service.id".
  final services = <String, String>{};

  @override
  Future<List<String>?> read(String profileId) async {
    reads.add(profileId);
    return null;
  }

  @override
  Future<String?> readService(String profileId, String service) async =>
      services['$service.$profileId'];

  @override
  Future<void> writeService(
    String profileId,
    String service,
    String? token,
  ) async => token == null
      ? services.remove('$service.$profileId')
      : services['$service.$profileId'] = token;

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

  test(
    'sync after Skip: the placeholder gives way and hands over its tokens',
    () async {
      final s = await start([]);
      core.openLibrary = _Library.new;
      await s.skipSetup('No provider yet');
      core.openLibrary = null;
      final placeholder = s.profile!;
      final secrets = s.secrets as NoSecrets;
      secrets.services['premiumize.${placeholder.id}'] = 'pm';
      core.profiles = [placeholder, profile('p1')];
      await s.afterDeviceSync(
        keysChanged: false,
        profile: profile('p1'),
        loginChanged: true,
      );
      expect(secrets.services, {'premiumize.p1': 'pm'});
      expect(core.deleted, [placeholder.id]);
      expect(s.profiles.map((p) => p.id), ['p1']);
      expect(
        secrets.reads.last,
        'p1',
        reason: 'then it opens the one that came',
      );
    },
  );

  test(
    'sync: the open profile reopens when it changed there, not otherwise',
    () async {
      final s = await start([]);
      final secrets = s.secrets as NoSecrets;
      s.profile = profile('p1');
      core.profiles = [profile('p1')];
      await s.afterDeviceSync(
        keysChanged: false,
        profile: profile('p1'),
        loginChanged: false,
      );
      expect(
        secrets.reads,
        isEmpty,
        reason: 'unchanged: only its lists refresh',
      );
      final moved = ProfileInfo(
        id: 'p1',
        name: 'Provider p1',
        source: SourceKind.xtream,
        server: 'http://moved.example.invalid',
        userAgent: '',
      );
      core.profiles = [moved];
      await s.afterDeviceSync(
        keysChanged: false,
        profile: moved,
        loginChanged: false,
      );
      expect(secrets.reads, ['p1'], reason: 'a new server: reopened');
    },
  );

  test('a single profile that cannot open: setup', () async {
    final s = await start([profile('a')]);
    expect(s.state, SessionState.needsSetup);
  });
}
