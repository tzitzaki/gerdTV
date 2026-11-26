// New, because nothing owned watch tracking on the app side: only linked services hear of a movie or episode,
// Trakt needs the user's own app (no secret ships with gerdTV), a refreshed token is stored, a removed profile
// deletes only the links it has, and items that aren't movies or episodes send nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/tracking.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:gerdtv/src/rust/api/tracking.dart';

import 'premiumize_test.dart' show MemorySecrets;
import 'support/fake_core.dart';

class _Library implements Library {
  @override
  Future<TrackItem?> trackItem({required String key}) async =>
      key.startsWith('movie:')
      ? const TrackItem(
          movie: true,
          name: 'Inception',
          year: 2010,
          show_: '',
          season: 0,
          number: 0,
          tmdb: null,
        )
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeCore core;
  setUpAll(() => core = useFakeCore());

  test(
    'scrobbles reach linked services only, refreshed tokens are kept',
    () async {
      const trakt = TrackService('trakt', 'Trakt', '', ownApp: true);
      const simkl = TrackService('simkl', 'Simkl', 'simkl-id');
      final secrets = MemorySecrets();
      final t = Tracking(secrets, services: const [trakt, simkl]);
      await t.load('p1');
      expect(
        t.client(trakt),
        isNull,
        reason: 'Trakt: the user\'s own app first',
      );
      expect(t.client(simkl), ('simkl-id', ''));
      final lib = _Library();

      await t.scrobble(lib, 'movie:1', 'start', 0);
      expect(core.scrobbles, isEmpty, reason: 'nothing linked');

      await t.link(simkl, '{"access":"a"}');
      await t.link(trakt, '{"access":"b"}');
      await t.scrobble(lib, 'movie:1', 'start', 0);
      expect(core.scrobbles, ['simkl start 0'], reason: 'Trakt has no app yet');

      await t.setApp(trakt, (' my-id ', 'my-secret'));
      core.scrobbleRefresh = '{"access":"fresh"}';
      await t.scrobble(lib, 'movie:1', 'stop', 91.2);
      expect(core.scrobbles.skip(1), ['trakt stop 91', 'simkl stop 91']);
      expect(secrets.services['simkl.p1'], '{"access":"fresh"}');
      expect(secrets.services['trakt-app.p1'], '["my-id","my-secret"]');

      // A mark by hand goes to Simkl's history; live TV sends nothing.
      await t.history(lib, 'movie:1', true);
      await t.history(lib, 'live:1', true);
      expect(core.history, ['true Inception']);

      await t.scrobble(lib, 'live:1', 'start', 0);
      expect(core.scrobbles, hasLength(3), reason: 'live TV is not tracked');

      // Reopened: links and the own app come back from the secure storage.
      final again = Tracking(secrets, services: const [trakt, simkl]);
      await again.load('p1');
      expect(again.client(trakt), ('my-id', 'my-secret'));
      expect(again.linked(simkl), isTrue);

      // The profile's removal deletes only what exists (deleting a never-written key crashed on Linux).
      secrets.writes.clear();
      await again.forget();
      expect(
        secrets.writes,
        unorderedEquals(['-trakt.p1', '-trakt-app.p1', '-simkl.p1']),
      );
      expect(secrets.services, isEmpty);
      final empty = MemorySecrets();
      final none = Tracking(empty, services: const [trakt, simkl]);
      await none.load('p2');
      await none.forget();
      expect(empty.writes, isEmpty, reason: 'nothing linked: nothing deleted');
    },
  );
}
