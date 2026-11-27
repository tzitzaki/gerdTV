// New, because nothing owns device pairing's screen yet: showing a code shows its QR and the code, and pairing with a
// found device shows who answered before anything is sent ("pair as you scan"); Sync then sends. Also the web player's
// screen: a login link with its QR, and ending a web session. The protocol and the
// merge rules are the core's tests (pairing.rs).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/devices_screen.dart';
import 'package:gerdtv/screens/web_player_screen.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/pairing.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

class _Secrets extends Secrets {
  @override
  Future<List<String>?> read(String profileId) async => null;

  @override
  Future<String?> readService(String profileId, String service) async => null;

  @override
  Future<void> writeService(
    String profileId,
    String service,
    String? token,
  ) async {}
}

class _Listener extends Fake implements PairListener {
  @override
  int port() => 4100;

  @override
  String newCode() => 'ABCD-EFGH-JKMN';

  @override
  void clearCode() {}

  @override
  void update({required LocalInfo local}) {}

  /// Nothing happens on this side in these tests.
  @override
  Future<PairEvent?> nextEvent() => Future.value(null);
}

const _tv = DeviceInfo(id: 'tv1', name: 'Living room TV', platform: 'android');

class _Connection extends Fake implements PairConnection {
  int sent = 0;

  @override
  DeviceInfo peer() => _tv;

  @override
  Future<AppliedInfo> exchange({required LocalInfo local}) async {
    sent++;
    return AppliedInfo(
      peer: _tv,
      peerAddr: '192.0.2.5:4100',
      newKey: 'k',
      keysUpdatedAt: 0,
    );
  }
}

class _PairingCore extends FakeCore {
  final connection = _Connection();
  String? typedCode;
  final webSessions = [
    WebSessionInfo(id: 's1', created: 0, expires: 0, agent: 'Firefox'),
  ];

  @override
  Future<String> crateApiPairingHostLink({
    required String meId,
    required PeerInfo peer,
  }) async => '${peer.web}/l/abc';

  @override
  Future<List<WebSessionInfo>> crateApiPairingHostSessions({
    required String meId,
    required PeerInfo peer,
  }) async => List.of(webSessions);

  @override
  Future<void> crateApiPairingHostEndSession({
    required String meId,
    required PeerInfo peer,
    required String id,
  }) async => webSessions.removeWhere((s) => s.id == id);

  @override
  String crateApiPairingPairNewDeviceId() => 'me1';

  @override
  String? crateApiPairingPairLocalIp() => '192.0.2.9';

  @override
  String crateApiPairingPairLinkText({
    required String addr,
    required String code,
  }) => 'gerdtv://pair?a=$addr&c=$code';

  @override
  QrInfo crateApiPairingPairQr({required String text}) =>
      QrInfo(width: 21, modules: List.filled(21 * 21, true));

  @override
  Future<PairListener> crateApiPairingPairListenerStart({
    required LocalInfo local,
    required bool announce,
  }) async => _Listener();

  @override
  Future<List<FoundDevice>> crateApiPairingPairDiscover({
    required String meId,
    required int waitMs,
  }) async => [const FoundDevice(device: _tv, addr: '192.0.2.5:4100')];

  @override
  Future<PairConnection> crateApiPairingPairConnectCode({
    required String addr,
    required String code,
    required DeviceInfo me,
    int? port,
  }) async {
    typedCode = code;
    return connection;
  }
}

void main() {
  late _PairingCore core;
  setUpAll(() => core = useFakeCore(_PairingCore()) as _PairingCore);

  Future<Session> show(WidgetTester tester) async {
    final session = Session(secrets: _Secrets(), appDir: '/nonexistent');
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: session.navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: DevicesScreen(session: session),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  testWidgets('show a code: its QR and the code', (tester) async {
    await show(tester);
    expect(find.byKey(const Key('devices.qr')), findsNothing);
    await tester.tap(find.byKey(const Key('devices.showCode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices.qr')), findsOneWidget);
    expect(find.text('ABCD-EFGH-JKMN'), findsOneWidget);
  });

  testWidgets('pair with a found device: who answered first, Sync sends', (
    tester,
  ) async {
    final session = await show(tester);
    await tester.tap(find.byKey(const Key('devices.found.tv1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('devices.codeField')),
      'abcd efgh jkmn',
    );
    await tester.tap(find.byKey(const Key('devices.connect')));
    await tester.pumpAndSettle();
    expect(core.typedCode, 'abcd efgh jkmn', reason: 'the core normalizes');
    expect(find.text('Sync with Living room TV (android)?'), findsOneWidget);
    expect(core.connection.sent, 0, reason: 'nothing sent before Sync');
    await tester.tap(find.byKey(const Key('devices.sync')));
    await tester.pumpAndSettle();
    expect(core.connection.sent, 1);
    // Remembered, with where it listens.
    expect(session.devices.peers.value.single.addr, '192.0.2.5:4100');
    expect(find.byKey(const Key('devices.peer.tv1')), findsOneWidget);
  });

  testWidgets('web player: a login link with its QR; End ends a session', (
    tester,
  ) async {
    final session = Session(secrets: _Secrets(), appDir: '/nonexistent');
    const host = PeerInfo(
      device: DeviceInfo(id: 'h1', name: 'gerdTV host', platform: 'host'),
      key: 'k',
      addr: '',
      web: 'https://tv.example.invalid',
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: WebPlayerScreen(session: session, host: host),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web.session.s1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('web.makeLink')));
    await tester.pumpAndSettle();
    expect(find.text('https://tv.example.invalid/l/abc'), findsOneWidget);
    expect(find.byKey(const Key('devices.qr')), findsOneWidget);
    await tester.ensureVisible(find.text('End')); // below the QR
    await tester.pumpAndSettle();
    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web.session.s1')), findsNothing);
  });
}
