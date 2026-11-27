// New, because nothing owns device pairing's screen yet: showing a code shows its QR and the code, and pairing with a
// found device shows who answered before anything is sent ("pair as you scan"); Sync then sends. Also the web player's
// screen: a login link with its QR, and ending a web session. And a start without paired devices leaves secure
// storage alone; extended: the Mac's webcam scan opens a pairing link's confirmation, other codes are refused. The protocol and the
// merge rules are the core's tests (pairing.rs).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/platform/platform_bridge.dart';
import 'package:gerdtv/screens/devices_screen.dart';
import 'package:gerdtv/screens/web_player_screen.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/pairing.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

class _Secrets extends Secrets {
  /// Every read of a service secret, as "service.id".
  final reads = <String>[];

  @override
  Future<List<String>?> read(String profileId) async => null;

  @override
  Future<String?> readService(String profileId, String service) async {
    reads.add('$service.$profileId');
    return null;
  }

  @override
  Future<void> writeService(
    String profileId,
    String service,
    String? token,
  ) async {}
}

/// Secure storage in memory, behind the real Secrets (so its change hook runs).
class _MemoryStorage extends Fake implements FlutterSecureStorage {
  final items = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String;
    switch (i.memberName) {
      case #read:
        return Future<String?>.value(items[key]);
      case #write:
        items[key] = i.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        items.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

class _Listener extends Fake implements PairListener {
  /// How often the app handed it a new state.
  int updates = 0;

  @override
  int port() => 4100;

  @override
  String newCode() => 'ABCD-EFGH-JKMN';

  @override
  void clearCode() {}

  @override
  void update({required LocalInfo local}) => updates++;

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
  PairLink? crateApiPairingPairParseLink({required String link}) =>
      link.startsWith('gerdtv://pair?')
      ? const PairLink(addr: '192.0.2.5:4100', code: 'ABCD-EFGH-JKMN')
      : null;

  @override
  String crateApiPairingPairLinkText({
    required String addr,
    required String code,
  }) => 'gerdtv://pair?a=$addr&c=$code';

  @override
  QrInfo crateApiPairingPairQr({required String text}) =>
      QrInfo(width: 21, modules: List.filled(21 * 21, true));

  final listener = _Listener();

  @override
  Future<PairListener> crateApiPairingPairListenerStart({
    required LocalInfo local,
    required bool announce,
  }) async => listener;

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

  test('a start without paired devices never reads secure storage', () async {
    // A first read before any write can wait on a keyring prompt on Linux; it froze the app's start under Xvfb.
    final secrets = _Secrets();
    final session = Session(secrets: secrets, appDir: '/nonexistent');
    core.appSettings.remove('paired_devices');
    await session.devices.init();
    expect(secrets.reads, isEmpty);
    core.appSettings['paired_devices'] = '1';
    await session.devices.init();
    expect(secrets.reads, ['peers.app'], reason: 'with one paired: the list');
    core.appSettings.remove('paired_devices');
  });

  test('a key or token changed here reaches the running listener', () async {
    // Else a sync started by the other device answers with the old keys and overwrites the new one.
    final secrets = Secrets(_MemoryStorage());
    final session = Session(secrets: secrets, appDir: '/nonexistent');
    await session.devices.init();
    await session.devices.startPairing();
    final before = core.listener.updates;
    session.devices.keysChanged();
    await Future<void>.delayed(Duration.zero);
    expect(core.listener.updates, greaterThan(before));
    final after = core.listener.updates;
    await secrets.writeService('p1', 'premiumize', 'pm');
    await Future<void>.delayed(Duration.zero);
    expect(core.listener.updates, greaterThan(after));
    session.devices.stopPairing();
  });

  testWidgets('the Mac scans a QR with its webcam; only a pairing link opens', (
    tester,
  ) async {
    PlatformBridge.canScanQr = true;
    addTearDown(() => PlatformBridge.canScanQr = false);
    var scanned = 'gerdtv://pair?a=192.0.2.5:4100&c=ABCD-EFGH-JKMN';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformBridge.channel,
      (call) async => call.method == 'scanQr' ? scanned : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformBridge.channel,
        null,
      ),
    );
    final session = await show(tester);
    await tester.tap(find.byKey(const Key('devices.scan')));
    await tester.pumpAndSettle();
    expect(
      session.devices.link.value,
      const PairLink(addr: '192.0.2.5:4100', code: 'ABCD-EFGH-JKMN'),
    );
    session.devices.link.value = null;
    scanned = 'https://example.invalid/menu';
    await tester.tap(find.byKey(const Key('devices.scan')));
    await tester.pumpAndSettle();
    expect(session.devices.link.value, isNull);
    expect(
      find.text("That QR code isn't a gerdTV pairing code."),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

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
