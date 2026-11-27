// Devices & sync (core: pairing.rs, which explains the protocol and the merge rules): pairs this install with another
// gerdTV (a phone, the TV, the Mac, the headless host) by a one-time code or QR, and syncs the open profile, its login,
// linked services, the app keys and the user data with remembered devices, two-way, on the local network only.
//
// How the pieces connect:
// - This device listens (PairListener in the core) while the pairing screen is open and, once a device is
//   remembered, while gerdTV runs, so the other side's "Sync now" reaches it. Only a code shown on screen or a
//   remembered device's key gets in.
// - What a sync brings is merged into the profile store and database by the core; the secrets come back here
//   (AppliedInfo) and go to secure storage, then Session reloads what changed.
// - Remembered devices (their key is a secret) are one JSON list in secure storage ("peers"); the app keys' change
//   time is an app setting, so the newer set wins on both sides.
// - The system camera opens gerdTV with gerdtv://pair?a=…&c=… (Android, iOS); [link] carries it to the UI, which asks
//   before sending.
//
// Debugging: "wrong or used code" = the code was typed wrong once (it is used up then; a new one shows). A device that
// never appears in the list: other network, guest Wi-Fi or client isolation; the QR still works (it has the address).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/platform_bridge.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/pairing.dart';
import 'session.dart';

class Devices {
  Devices(this._session);
  final Session _session;

  /// App setting: this install's random id (made on first use).
  static const settingDeviceId = 'device_id';

  /// App setting: when the app keys (TMDB, OpenSubtitles) were last changed here (unix seconds).
  static const settingKeysUpdatedAt = 'keys_updated_at';

  /// App setting: how many devices are remembered. The list itself is in secure storage, which is read only when
  /// this says there is one: a start without paired devices never touches the keyring (on Linux a first read before
  /// any write can wait on a keyring prompt, and froze the app under Xvfb).
  static const settingPaired = 'paired_devices';

  /// The app-wide secrets' id (Session keeps the TMDB and OpenSubtitles keys under it too).
  static const _app = 'app';

  /// The app keys that travel, by their secure-storage name.
  static const appKeyNames = ['tmdb', 'opensubtitles', 'opensubtitles-login'];

  /// A profile's linked services' secrets that travel: the tokens, and Trakt's/Simkl's own app (tracking.dart).
  static const serviceNames = [
    'premiumize',
    'trakt',
    'trakt-app',
    'simkl',
    'simkl-app',
  ];

  /// Remembered devices.
  final peers = ValueNotifier<List<PeerInfo>>(const []);

  /// The code the pairing screen shows (formatted); null while not pairing.
  final code = ValueNotifier<String?>(null);

  /// The last sync another device started here, or the last failure, for the screens to show.
  final applied = ValueNotifier<AppliedInfo?>(null);
  final failed = ValueNotifier<String?>(null);

  /// A pairing link from the camera, waiting for the user's yes.
  final link = ValueNotifier<PairLink?>(null);

  PairListener? _listener;
  Future<PairListener>? _starting;

  /// iOS can't announce itself by mDNS without an entitlement: there the QR (with the address) does it.
  static bool get _announce => !Platform.isIOS;

  /// This install as others see it.
  DeviceInfo get me {
    final dir = _session.appDir!;
    var id = appSetting(dir: dir, key: settingDeviceId);
    if (id == null || id.isEmpty) {
      id = pairNewDeviceId();
      setAppSetting(dir: dir, key: settingDeviceId, value: id);
    }
    final host = Platform.localHostname;
    return DeviceInfo(
      id: id,
      // Phones report "localhost": the platform says more then.
      name: host.isEmpty || host == 'localhost' ? platformName : host,
      platform: Platform.operatingSystem,
    );
  }

  static String get platformName => switch (Platform.operatingSystem) {
    'android' => 'Android',
    'ios' => 'iPhone/iPad',
    'macos' => 'Mac',
    'linux' => 'Linux',
    final o => o,
  };

  /// Called once the session started: remembered devices, the camera's link, and listening if anyone is paired.
  Future<void> init() async {
    // Any secret changed (a key, a token, a login): the listener answers with the new state.
    _session.secrets.onChange = () => unawaited(refresh());
    PlatformBridge.onPairLink = _onLink;
    final first = await PlatformBridge.takePairLink();
    if (first != null) _onLink(first);
    final paired = appSetting(dir: _session.appDir!, key: settingPaired);
    if ((int.tryParse(paired ?? '') ?? 0) == 0) return;
    final raw = await _session.secrets.readService(_app, 'peers');
    if (raw != null) {
      try {
        peers.value = [
          for (final p in jsonDecode(raw) as List)
            PeerInfo(
              device: DeviceInfo(
                id: p['id'] as String,
                name: p['name'] as String,
                platform: p['platform'] as String,
              ),
              key: p['key'] as String,
              addr: p['addr'] as String,
              web: p['web'] as String? ?? '',
            ),
        ];
      } catch (_) {
        // Unreadable (e.g. written by a newer gerdTV): start over rather than fail the start.
      }
    }
    if (peers.value.isNotEmpty) await _listen();
  }

  void _onLink(String raw) => link.value = pairParseLink(link: raw);

  Future<void> _savePeers() async {
    setAppSetting(
      dir: _session.appDir!,
      key: settingPaired,
      value: '${peers.value.length}',
    );
    await _session.secrets.writeService(
      _app,
      'peers',
      jsonEncode([
        for (final p in peers.value)
          {
            'id': p.device.id,
            'name': p.device.name,
            'platform': p.device.platform,
            'key': p.key,
            'addr': p.addr,
            'web': p.web,
          },
      ]),
    );
  }

  /// What this device offers a sync right now.
  Future<LocalInfo> local() async {
    final s = _session;
    final keys = <String, String>{};
    for (final name in appKeyNames) {
      final v = await s.secrets.readService(_app, name);
      if (v != null) keys[name] = v;
    }
    final p = s.profile;
    ProfileSecretsInfo? profile;
    if (p != null && s.hasProvider) {
      final services = <String, String>{};
      for (final name in serviceNames) {
        final v = await s.secrets.readService(p.id, name);
        if (v != null) services[name] = v;
      }
      profile = ProfileSecretsInfo(
        id: p.id,
        login: await s.secrets.read(p.id) ?? const [],
        services: services,
      );
    }
    return LocalInfo(
      dir: s.appDir!,
      me: me,
      appKeys: keys,
      keysUpdatedAt:
          int.tryParse(
            appSetting(dir: s.appDir!, key: settingKeysUpdatedAt) ?? '',
          ) ??
          0,
      profile: profile,
      peers: peers.value,
      port: _listener?.port(),
    );
  }

  /// The app keys changed here: they win at the next sync (and the listener answers with them from now on).
  void keysChanged() {
    setAppSetting(
      dir: _session.appDir!,
      key: settingKeysUpdatedAt,
      value: '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    );
    unawaited(refresh());
  }

  /// The open profile, its secrets or the peers changed: the listener answers with the new state.
  Future<void> refresh() async {
    final l = _listener;
    if (l != null) l.update(local: await local());
  }

  Future<PairListener> _listen() async {
    final l = _listener;
    if (l != null) return l;
    return _starting ??= () async {
      final listener = await PairListener.start(
        local: await local(),
        announce: _announce,
      );
      _listener = listener;
      await refresh(); // now with its port
      unawaited(_events(listener));
      return listener;
    }();
  }

  Future<void> _events(PairListener l) async {
    while (true) {
      final e = await l.nextEvent();
      if (e == null) return;
      // One failing event (a secure-storage write refused, a profile that won't open) must not end the loop: later
      // syncs would be merged by the core but their secrets never stored.
      try {
        if (e.newCode != null) {
          if (code.value != null) code.value = e.newCode;
        } else if (e.failed != null) {
          failed.value = e.failed;
        } else if (e.applied != null) {
          await _apply(e.applied!);
          applied.value = e.applied;
        }
      } catch (err) {
        failed.value = '$err';
      }
    }
  }

  /// The pairing screen opens: listen (and announce), with a fresh code; returns the QR's text.
  Future<String> startPairing() async {
    await _multicast(true);
    final l = await _listen();
    code.value = l.newCode();
    return qrText()!;
  }

  void stopPairing() {
    _listener?.clearCode();
    code.value = null;
    unawaited(_multicast(false));
  }

  /// The QR's text for the code shown (null while not pairing).
  String? qrText() {
    final l = _listener, c = code.value;
    final ip = pairLocalIp();
    if (l == null || c == null || ip == null) return null;
    return pairLinkText(addr: '$ip:${l.port()}', code: c);
  }

  /// Android drops multicast (mDNS) unless the app holds a lock; the pairing screen and a discovery take it.
  Future<void> _multicast(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await PlatformBridge.channel.invokeMethod('multicastLock', {'on': on});
    } catch (_) {}
  }

  /// gerdTV devices on the network (not on iOS, which can't browse without an entitlement: scan their QR there).
  Future<List<FoundDevice>> discover() async {
    if (Platform.isIOS) return const [];
    await _multicast(true);
    try {
      return await pairDiscover(meId: me.id, waitMs: 2500);
    } finally {
      if (code.value == null) await _multicast(false);
    }
  }

  /// Says hello with the code another device shows; nothing is sent until [exchange].
  Future<PairConnection> connectCode(String addr, String code) async =>
      pairConnectCode(addr: addr, code: code, me: me, port: _listener?.port());

  /// Sends and takes, merges and stores what came; remembers the device. Returns what changed here.
  Future<AppliedInfo> exchange(PairConnection c, {required String addr}) async {
    // A remembered device can sync back to this one from now on: listen before telling it the port.
    await _listen();
    final a = await c.exchange(local: await local());
    await _apply(a, addr: a.peerAddr ?? addr);
    return a;
  }

  /// Syncs with a remembered device: found by mDNS where it announces itself, else where it was reached last.
  Future<AppliedInfo> syncNow(PeerInfo peer) async {
    final found = await discover();
    final addr =
        found.where((f) => f.device.id == peer.device.id).firstOrNull?.addr ??
        peer.addr;
    if (addr.isEmpty) throw 'not found on this network';
    final c = await pairConnectPeer(
      addr: addr,
      me: me,
      port: _listener?.port(),
      peer: peer,
    );
    final a = await c.exchange(local: await local());
    await _apply(a, addr: a.peerAddr ?? addr);
    return a;
  }

  Future<void> forget(PeerInfo peer) async {
    peers.value = [
      for (final p in peers.value)
        if (p.device.id != peer.device.id) p,
    ];
    await _savePeers();
    await refresh();
  }

  /// Stores what a sync brought: the peer, the app keys, the profile's login and services; then the session reloads.
  Future<void> _apply(AppliedInfo a, {String? addr}) async {
    final s = _session;
    final known = peers.value.where((p) => p.device.id == a.peer.id);
    final key = a.newKey ?? known.firstOrNull?.key;
    if (key != null) {
      peers.value = [
        for (final p in peers.value)
          if (p.device.id != a.peer.id) p,
        PeerInfo(
          device: a.peer,
          key: key,
          addr: addr ?? a.peerAddr ?? known.firstOrNull?.addr ?? '',
          web: a.peerWeb ?? known.firstOrNull?.web ?? '',
        ),
      ];
      await _savePeers();
    }
    final keys = a.appKeys;
    if (keys != null) {
      for (final name in appKeyNames) {
        final v = keys[name];
        // Only delete what exists: deleting a never-written key crashes the Linux keyring plugin (Session.removeProfile).
        if (v != null || await s.secrets.readService(_app, name) != null) {
          await s.secrets.writeService(_app, name, v);
        }
      }
      setAppSetting(
        dir: s.appDir!,
        key: settingKeysUpdatedAt,
        value: '${a.keysUpdatedAt}',
      );
    }
    final p = a.profile;
    if (p != null) {
      if (p.login != null) await s.secrets.write(p.profile.id, p.login!);
      for (final e in p.services.entries) {
        await s.secrets.writeService(p.profile.id, e.key, e.value);
      }
    }
    await s.afterDeviceSync(
      keysChanged: keys != null,
      profile: p?.profile,
      loginChanged: p?.login != null,
    );
    await refresh();
  }
}
