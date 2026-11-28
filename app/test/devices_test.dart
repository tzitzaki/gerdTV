// New, because nothing owns device pairing's screen yet: showing a code shows its QR and the code, and pairing with a
// found device shows who answered before anything is sent ("pair as you scan"); Sync then sends. Also the web player's
// screen: a login link with its QR, and ending a web session. And a start without paired devices leaves secure
// storage alone; extended: the Mac's webcam scan opens a pairing link's confirmation, other codes are refused; extended:
// the first run's welcome screen listens at once (QR and code), folds the phone files (computer only) and fades the
// nearby list until it has the focus, and Skip opens
// the app without a provider; extended: auto-sync with the paired host (at once, then only for a settled change);
// extended: the relay (a host found nearby, named in the QR, a typed one wins). The protocol and the
// merge rules are the core's tests (pairing.rs).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/platform/platform_bridge.dart';
import 'package:gerdtv/screens/devices_screen.dart';
import 'package:gerdtv/screens/web_player_screen.dart';
import 'package:gerdtv/screens/welcome_screen.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';
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
  String newCode() => '482 913';

  @override
  void clearCode() {}

  @override
  void update({required LocalInfo local}) => updates++;

  /// The relay the app told it to wait at.
  String? relay;

  @override
  void setRelay({String? web}) => relay = web;

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

/// A library whose user data is [data] (auto-sync fingerprints the export).
class _Library extends Fake implements Library {
  String data = '{}';

  @override
  Future<String> exportUserData() async => data;
}

class _PairingCore extends FakeCore {
  final connection = _Connection();

  /// Remembered-device syncs started (auto-sync's rounds).
  int peerSyncs = 0;

  @override
  Future<PairConnection> crateApiPairingPairConnectPeer({
    required String addr,
    required DeviceInfo me,
    int? port,
    required PeerInfo peer,
    String? relayWeb,
  }) async {
    peerSyncs++;
    return _Connection();
  }

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
  String? crateApiPairingPairLocalIp() => '192.0.2.9';

  @override
  PairLink? crateApiPairingPairParseLink({required String link}) =>
      link.startsWith('gerdtv://pair?')
      ? const PairLink(addr: '192.0.2.5:4100', code: '482 913')
      : null;

  @override
  String crateApiPairingPairLinkText({
    required String addr,
    required String code,
    String? relayWeb,
    required String meId,
  }) =>
      'gerdtv://pair?a=$addr&c=$code${relayWeb == null ? '' : '&r=$relayWeb&m=$meId'}';

  final listener = _Listener();

  @override
  Future<PairListener> crateApiPairingPairListenerStart({
    required LocalInfo local,
    required bool announce,
  }) async => listener;

  /// A host on the network announcing its front address (null: none found).
  String? hostWeb;

  @override
  Future<List<FoundDevice>> crateApiPairingPairDiscover({
    required String meId,
    required int waitMs,
  }) async => [
    const FoundDevice(device: _tv, addr: '192.0.2.5:4100'),
    if (hostWeb != null)
      FoundDevice(
        device: const DeviceInfo(
          id: 'h1',
          name: 'gerdTV host',
          platform: 'host',
        ),
        addr: '192.0.2.6:8791',
        web: hostWeb,
      ),
  ];

  @override
  Future<PairConnection> crateApiPairingPairConnectCode({
    required String addr,
    required String code,
    required DeviceInfo me,
    int? port,
    String? relayWeb,
    String? bell,
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
    var scanned = 'gerdtv://pair?a=192.0.2.5:4100&c=482913';
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
      const PairLink(addr: '192.0.2.5:4100', code: '482 913'),
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
    expect(find.text('482 913'), findsOneWidget);
  });

  testWidgets('welcome: the code at once, phone files, Skip opens the app', (
    tester,
  ) async {
    final session = Session(secrets: _Secrets(), appDir: '/nonexistent')
      ..state = SessionState.needsSetup;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: session.navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: WelcomeScreen(session: session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('482 913'), findsOneWidget, reason: 'no tap needed');
    // The code card keeps its width whatever this device is called (a long host name overflowed CI's 800 px window).
    expect(
      tester.getSize(find.byKey(const Key('welcome.code'))).width,
      lessThanOrEqualTo(260),
    );
    expect(find.byKey(const Key('devices.found.tv1')), findsOneWidget);
    // Calm: the nearby list faded, the phone files folded. The test runs as a computer: both files, as QRs.
    double nearby() => tester
        .widget<AnimatedOpacity>(find.byKey(const Key('welcome.nearby')))
        .opacity;
    expect(nearby(), lessThan(1));
    expect(find.byKey(const Key('welcome.get.android')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('welcome.apps')));
    await tester.tap(find.byKey(const Key('welcome.apps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome.get.android')), findsOneWidget);
    expect(find.byKey(const Key('welcome.get.ios')), findsOneWidget);
    // Down from Skip (the first focus) passes the button and reaches the nearby list, which comes forward.
    for (final shown in [false, true]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(nearby() == 1, shown);
    }
    await tester.ensureVisible(find.byKey(const Key('welcome.skip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('welcome.skip')));
    await tester.pumpAndSettle();
    // Skip saved a profile without a provider (opening it is the session's part, app_test's journey).
    expect(session.profiles.single.source, SourceKind.none);
    await tester.pumpWidget(const SizedBox()); // stops pairing
  });

  testWidgets('relay: a host found nearby, named in the QR; a typed one wins', (
    tester,
  ) async {
    core.hostWeb = 'https://tv.example.invalid';
    addTearDown(() => core.hostWeb = null);
    final session = await show(tester);
    await tester.tap(find.byKey(const Key('devices.showCode')));
    await tester.pumpAndSettle();
    expect(session.devices.qrText(), contains('&r=https://tv.example.invalid'));
    expect(core.listener.relay, 'https://tv.example.invalid');
    final field = find.byKey(const Key('devices.relay'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'not an address');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      core.listener.relay,
      'https://tv.example.invalid',
      reason: 'refused',
    );
    await tester.enterText(field, 'https://other.example.invalid');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(core.listener.relay, 'https://other.example.invalid');
    // Empty: back to the one found.
    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(core.listener.relay, 'https://tv.example.invalid');
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'auto-sync with the host: at once, then only for a settled change',
    () async {
      final session = Session(secrets: _Secrets(), appDir: '/nonexistent');
      final lib = _Library();
      session.library = lib;
      final d = session.devices;
      d.peers.value = [
        const PeerInfo(
          device: DeviceInfo(id: 'h1', name: 'gerdTV host', platform: 'host'),
          key: 'k',
          addr: '192.0.2.6:8791',
          web: 'https://tv.example.invalid',
        ),
      ];
      final before = core.peerSyncs;
      int syncs() => core.peerSyncs - before;
      await d.autoSync(); // the start's round
      expect(syncs(), 1);
      await d.checkAutoSync();
      expect(syncs(), 1, reason: 'nothing changed, and what came is no change');
      lib.data = '{"favourites":[1]}';
      await d.checkAutoSync();
      expect(syncs(), 1, reason: 'still changing: wait one check');
      await d.checkAutoSync();
      expect(syncs(), 2, reason: 'settled: sent');
      d.keysChanged();
      await d.checkAutoSync();
      expect(syncs(), 3, reason: 'a changed key goes at once');
    },
  );

  testWidgets('pair with a found device: who answered first, Sync sends', (
    tester,
  ) async {
    final session = await show(tester);
    await tester.tap(find.byKey(const Key('devices.found.tv1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('devices.codeField')),
      '482 913',
    );
    await tester.tap(find.byKey(const Key('devices.connect')));
    await tester.pumpAndSettle();
    expect(core.typedCode, '482 913', reason: 'the core normalizes');
    expect(find.text('Sync with Living room TV (android)?'), findsOneWidget);
    expect(core.connection.sent, 0, reason: 'nothing sent before Sync');
    await tester.tap(find.byKey(const Key('devices.sync')));
    await tester.pumpAndSettle();
    expect(core.connection.sent, 1);
    // Remembered, with where it listens.
    expect(session.devices.peers.value.single.addr, '192.0.2.5:4100');
    expect(find.byKey(const Key('devices.peer.tv1')), findsOneWidget);
    // Forget sits in the row's ⋮.
    await tester.tap(find.byKey(const Key('devices.peerMenu.tv1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('devices.forget.tv1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget')); // confirmed
    await tester.pumpAndSettle();
    expect(session.devices.peers.value, isEmpty);
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
    // The code is the big text (typed on the front door's page); Copy takes the whole link.
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('web.code'))).data,
      'abc',
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.tap(find.byKey(const Key('code.copy')));
    expect(copied, 'https://tv.example.invalid/l/abc');
    // Below the code card (the page's list is the first scrollable; selectable texts have their own).
    await tester.scrollUntilVisible(
      find.text('End'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web.session.s1')), findsNothing);
  });
}
