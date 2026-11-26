// Google Cast (core: cast.rs): find devices, cast what plays, and remote-control it from the now-playing bar.
// While casting, nothing plays here: the account's one connection belongs to the device (or to gerdTV's own HLS, the
// live fallback, which this device serves to it). The first cast says once that the provider's address, with the
// login in it, goes to the device (owner decision).
// Discovery: mDNS in the core (desktop, Android with a multicast lock); iOS: Apple's Bonjour browser in Swift.
// Debugging: no devices: the same network? On iOS, Settings → Privacy → Local Network; a cast that ends at once:
// the device's own error is in the debug log as "cast: …".

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/platform_bridge.dart';
import '../src/rust/api/cast.dart';
import '../src/rust/api/library.dart';
import 'session.dart';

/// The app-wide setting that the login notice was shown.
const settingCastNoted = 'cast_noted';

/// Whether [item] can be cast: the library's channels, movies and episodes (not catch-up, Premiumize or recordings).
bool castable(ItemInfo item) =>
    !item.key.startsWith('catchup:') &&
    !item.key.startsWith('premiumize:') &&
    !item.key.startsWith('recording:');

class Casting {
  Casting(this._session);
  final Session _session;
  Timer? _watch;

  /// What casts now: the device's name and the item; null when nothing does.
  final active = ValueNotifier<({String device, ItemInfo item, bool paused})?>(
    null,
  );
  CastHandle? _handle;

  /// Devices on the network (a few seconds).
  Future<List<CastDeviceInfo>> find() async {
    if (!kIsWeb && Platform.isIOS) {
      final list = await PlatformBridge.channel
          .invokeListMethod<Map<Object?, Object?>>('castDevices', {
            'seconds': 3.0,
          });
      return [
        for (final d in list ?? const <Map<Object?, Object?>>[])
          CastDeviceInfo(
            name: d['name']! as String,
            host: d['host']! as String,
            port: d['port']! as int,
          ),
      ];
    }
    await _multicast(true);
    try {
      return await castDiscover(secs: 3);
    } finally {
      await _multicast(false);
    }
  }

  Future<void> _multicast(bool on) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await PlatformBridge.channel.invokeMethod('multicastLock', {'on': on});
    } on MissingPluginException {
      // Tests.
    }
  }

  /// Moves [item] to [device]; throws the device's reason when neither route played.
  Future<void> start(CastDeviceInfo device, ItemInfo item) async {
    final lib = _session.library;
    if (lib == null) return;
    await stop();
    // The device takes the connection.
    await _session.stopPlayback();
    _handle = await lib.castStart(
      device: device,
      key: item.key,
      title: item.name,
      cacheDir: (await getTemporaryDirectory()).path,
    );
    active.value = (device: device.name, item: item, paused: false);
    // Ended over there (its remote, another app, out of reach): the bar goes.
    _watch = Timer.periodic(const Duration(seconds: 5), (_) async {
      final h = _handle;
      if (h != null && !await h.playing()) await stop();
    });
  }

  Future<void> togglePause() async {
    final a = active.value;
    if (a == null) return;
    await _handle?.pause(pause: !a.paused);
    active.value = (device: a.device, item: a.item, paused: !a.paused);
  }

  Future<void> stop() async {
    _watch?.cancel();
    _watch = null;
    final h = _handle;
    _handle = null;
    active.value = null;
    await h?.stop();
  }
}
