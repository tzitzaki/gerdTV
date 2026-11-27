// Devices & sync (core: pairing.rs, which explains the protocol and the merge rules): pairs this install with another
// gerdTV (a phone, the TV, the Mac, the headless host) by a one-time code or QR, and syncs the open profile, its login,
// linked services, the app keys and the user data with remembered devices, two-way: on the local network first, and
// across networks through the user's own gerdTV host (core relay.rs) when a relay address is known.
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
// - The relay ([relay]): one address, typed (Devices & sync, the welcome screen), else a paired host's front address,
//   else one a host announced on this network. While this device listens it waits at its doorbell there, the QR
//   names it, and Sync now falls back to it when the other device isn't on this network.
// - Auto-sync (owner decision: the apps keep themselves in step, at home and away): the paired host is the hub, so
//   every app syncs with it by itself ([autoSync]): when gerdTV starts or comes back to the front, and once a change
//   here has settled (the user data's export unchanged for one check, [autoSyncEvery], so playback's progress waits
//   until it stops; changed keys, logins and tokens count too). What a sync brings doesn't count as a change, so two
//   apps never sync back and forth. A failure is quiet and waits [autoSyncRetry] (or the next return to the front).
//
// Debugging: "wrong or used code" = the code was typed wrong once (it is used up then; a new one shows). A device that
// never appears in the list: other network, guest Wi-Fi or client isolation; the QR still works (it has the address,
// and the relay's when one is known). A relayed pairing that times out: the other device has no or another relay.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

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

  /// App setting: the relay address typed in; empty = found automatically ([relay]).
  static const settingRelay = 'relay_web';

  /// App setting: how many devices are remembered. The list itself is in secure storage, which is read only when
  /// this says there is one: a start without paired devices never touches the keyring (on Linux a first read before
  /// any write can wait on a keyring prompt, and froze the app under Xvfb).
  static const settingPaired = 'paired_devices';

  /// The app-wide secrets' id (Session keeps the TMDB and OpenSubtitles keys under it too).
  static const _app = 'app';

  /// The app keys that travel, by their secure-storage name.
  static const appKeyNames = ['tmdb', 'opensubtitles', 'opensubtitles-login'];

  /// A profile's linked services' secrets that travel: the tokens, and the own apps (tracking.dart, Premiumize's).
  static const serviceNames = [
    'premiumize',
    'premiumize-app',
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

  /// Where devices on different networks meet (the host's front address), or null: the LAN only.
  final relay = ValueNotifier<String?>(null);

  /// A front address a host announced on this network (mDNS), for this run.
  String? _foundRelay;

  PairListener? _listener;
  Future<PairListener>? _starting;

  /// How often auto-sync looks for a settled change, and how long it waits after a failed round.
  static const autoSyncEvery = Duration(seconds: 30);
  static const autoSyncRetry = Duration(minutes: 5);
  Timer? _autoTimer;
  AppLifecycleListener? _lifecycle;

  /// The user data's fingerprint at the last auto-sync and at the last check.
  int? _syncedStamp, _seenStamp;

  /// A key, login or token changed here since the last auto-sync.
  bool _secretsChanged = false;

  /// What a sync brought is being stored: those writes aren't changes to send back.
  bool _applying = false;
  bool _autoRunning = false;
  DateTime? _autoFailed;

  /// The paired hosts (a remembered peer with a web address).
  Iterable<PeerInfo> get _hosts => peers.value.where((p) => p.web.isNotEmpty);

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
    // Any secret changed (a key, a token, a login): the listener answers with the new state, and auto-sync sends it.
    _session.secrets.onChange = () {
      if (!_applying) _secretsChanged = true;
      unawaited(refresh());
    };
    PlatformBridge.onPairLink = _onLink;
    final first = await PlatformBridge.takePairLink();
    if (first != null) _onLink(first);
    _updateRelay();
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
    _updateRelay(); // a paired host's address
    if (peers.value.isNotEmpty) await _listen();
    _startAutoSync();
    unawaited(autoSync()); // at the start
  }

  /// The relay typed in (empty: none typed).
  String get typedRelay =>
      appSetting(dir: _session.appDir!, key: settingRelay) ?? '';

  /// Stores a typed relay address (empty: back to the automatic one).
  void setTypedRelay(String web) {
    setAppSetting(dir: _session.appDir!, key: settingRelay, value: web.trim());
    _updateRelay();
  }

  /// Picks the relay (typed, a paired host's, one found nearby) and tells the listener, which waits at its doorbell
  /// there (the same address again changes nothing in the core).
  void _updateRelay() {
    final host = peers.value.map((p) => p.web).where((w) => w.isNotEmpty);
    final typed = typedRelay;
    relay.value = typed.isNotEmpty ? typed : host.firstOrNull ?? _foundRelay;
    _listener?.setRelay(web: relay.value);
  }

  void _onLink(String raw) => openLink(raw);

  /// A pairing link from the system camera or the Mac's webcam: opens its confirmation; false when [raw] isn't one.
  bool openLink(String raw) {
    final l = pairParseLink(link: raw);
    if (l != null) link.value = l;
    return l != null;
  }

  Future<void> _savePeers() async {
    _updateRelay(); // a host paired or forgotten
    _startAutoSync();
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

  /// Auto-sync runs while a host is paired: a check every [autoSyncEvery] and a round on every return to the front.
  void _startAutoSync() {
    if (_hosts.isEmpty) {
      _autoTimer?.cancel();
      _autoTimer = null;
      return;
    }
    _autoTimer ??= Timer.periodic(
      autoSyncEvery,
      (_) => unawaited(checkAutoSync()),
    );
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        _autoFailed = null; // back at the front: try at once
        unawaited(autoSync());
      },
    );
  }

  /// The user data's fingerprint (its export, as Settings → Your data writes it), or null without a profile.
  Future<int?> _stamp() async =>
      (await _session.library?.exportUserData())?.hashCode;

  /// One check: syncs when something changed here and has settled since the last check.
  @visibleForTesting
  Future<void> checkAutoSync() async {
    final stamp = await _stamp();
    final settled = stamp == _seenStamp;
    _seenStamp = stamp;
    if ((settled && stamp != _syncedStamp) || _secretsChanged) await autoSync();
  }

  /// Syncs with every paired host now (LAN first, then the relay), quietly; skipped while one runs or shortly after
  /// a failed round.
  Future<void> autoSync() async {
    final failed = _autoFailed;
    if (_autoRunning ||
        _hosts.isEmpty ||
        (failed != null && DateTime.now().difference(failed) < autoSyncRetry)) {
      return;
    }
    _autoRunning = true;
    try {
      var ok = true;
      for (final h in _hosts.toList()) {
        try {
          await syncNow(h);
        } catch (e) {
          ok = false;
          debugPrint('auto-sync with ${h.device.name}: $e');
        }
      }
      _autoFailed = ok ? null : DateTime.now();
      if (ok) {
        _secretsChanged = false;
        // What came is part of the state now: only later changes start the next round.
        _syncedStamp = _seenStamp = await _stamp();
      }
    } finally {
      _autoRunning = false;
    }
  }

  /// The app keys changed here: they win at the next sync (and the listener answers with them from now on).
  void keysChanged() {
    setAppSetting(
      dir: _session.appDir!,
      key: settingKeysUpdatedAt,
      value: '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    );
    _secretsChanged = true;
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
      listener.setRelay(web: relay.value);
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
    return pairLinkText(
      addr: '$ip:${l.port()}',
      code: c,
      relayWeb: relay.value,
      meId: me.id,
    );
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
      final found = await pairDiscover(meId: me.id, waitMs: 2500);
      // A host at home announces its front address: the relay, without typing.
      final web = found.map((f) => f.web).nonNulls.firstOrNull;
      if (web != null && web != _foundRelay) {
        _foundRelay = web;
        _updateRelay();
      }
      return found;
    } finally {
      if (code.value == null) await _multicast(false);
    }
  }

  /// Says hello with the code another device shows (on the LAN at [addr], else through the relay its QR named);
  /// nothing is sent until [exchange].
  Future<PairConnection> connectCode(
    String addr,
    String code, {
    String? relayWeb,
    String? bell,
  }) async => pairConnectCode(
    addr: addr,
    code: code,
    me: me,
    port: _listener?.port(),
    relayWeb: relayWeb,
    bell: bell,
  );

  /// Sends and takes, merges and stores what came; remembers the device. Returns what changed here.
  Future<AppliedInfo> exchange(PairConnection c, {required String addr}) async {
    // A remembered device can sync back to this one from now on: listen before telling it the port.
    await _listen();
    final a = await c.exchange(local: await local());
    await _apply(a, addr: a.peerAddr ?? (addr.isEmpty ? null : addr));
    return a;
  }

  /// Syncs with a remembered device: found by mDNS where it announces itself, else where it was reached last, else
  /// at its doorbell on the relay (another network).
  Future<AppliedInfo> syncNow(PeerInfo peer) async {
    final found = await discover();
    final addr =
        found.where((f) => f.device.id == peer.device.id).firstOrNull?.addr ??
        peer.addr;
    if (addr.isEmpty && relay.value == null) throw 'not found on this network';
    final c = await pairConnectPeer(
      addr: addr,
      me: me,
      port: _listener?.port(),
      peer: peer,
      relayWeb: relay.value,
    );
    final a = await c.exchange(local: await local());
    // Through the relay the LAN address stays what it was.
    await _apply(a, addr: a.peerAddr ?? (addr.isEmpty ? null : addr));
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
  /// These writes aren't local changes for auto-sync.
  Future<void> _apply(AppliedInfo a, {String? addr}) async {
    _applying = true;
    try {
      await _store(a, addr: addr);
    } finally {
      _applying = false;
    }
  }

  Future<void> _store(AppliedInfo a, {String? addr}) async {
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
