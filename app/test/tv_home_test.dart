// New, because nothing owns the home screen's entries: one that started the app waits for the profile to open, and one
// of another profile opens nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/platform_bridge.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/services/tv_home.dart';
import 'package:gerdtv/src/rust/api/library.dart';

class _Library extends Fake implements Library {}

ProfileInfo profile(String id) => ProfileInfo(
  id: id,
  name: id,
  source: SourceKind.xtream,
  server: '',
  userAgent: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (open, want) in [
    ('a', ['live:1']),
    ('b', <String>[]),
  ]) {
    test('an entry of profile a with profile $open open', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            PlatformBridge.channel,
            (call) async => call.method == 'takeOpenItem'
                ? {'profile': 'a', 'key': 'live:1'}
                : null,
          );
      final opened = <String>[];
      final session = Session(appDir: '/nonexistent');
      // Tests run as Android (Flutter's default), so the platform is asked.
      await TvHome(session, onOpen: opened.add).init();
      expect(opened, isEmpty, reason: 'no profile yet');
      session.library = _Library();
      session.profile = profile(open);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      session.notifyListeners();
      expect(opened, want);
    });
  }
}
