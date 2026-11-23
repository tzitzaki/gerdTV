// New, because nothing owns which profile opens at start: one opens by itself, several show the picker with the last
// one used first, "Always open this one" skips the picker, and a profile that can't open falls back to the picker.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';

import 'support/fake_core.dart';

/// No stored secrets: opening any Xtream Codes profile fails, which is what the fallbacks need.
class NoSecrets extends Secrets {
  @override
  Future<List<String>?> read(String profileId) async => null;
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

  test('a single profile that cannot open: setup', () async {
    final s = await start([profile('a')]);
    expect(s.state, SessionState.needsSetup);
  });
}
