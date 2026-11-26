// The Android TV home screen (Play Next and gerdTV's row of recent channels; native side: TvHome.kt): sends what they
// should hold whenever playback stops or changes, a profile opens or groups are hidden, and opens what is picked there.
// An entry of another profile than the open one opens nothing: its keys mean something else here.

import 'dart:async';

import '../platform/platform_bridge.dart';
import '../src/rust/api/library.dart';
import 'session.dart';

class TvHome {
  TvHome(this._session, {required this.onOpen}) {
    _session.nowPlaying.addListener(_update);
    _session.addListener(_onSession);
    PlatformBridge.onOpenItem = _open;
  }

  final Session _session;
  final void Function(String itemKey) onOpen;
  ({String profile, String key})? _wanted;
  Library? _updatedFor;
  int _generation = -1;

  /// What started the app, if a home screen entry did.
  Future<void> init() async {
    final first = await PlatformBridge.takeOpenItem();
    if (first != null) _open(first.profile, first.key);
  }

  void _open(String profile, String key) {
    _wanted = (profile: profile, key: key);
    _openWanted();
  }

  /// Started from the home screen, the profile is still opening: then when it has.
  void _openWanted() {
    final w = _wanted;
    final open = _session.profile?.id;
    if (w == null || open == null || _session.library == null) return;
    _wanted = null;
    if (w.profile == open) onOpen(w.key);
  }

  void _onSession() {
    _openWanted();
    if (identical(_session.library, _updatedFor) &&
        _session.generation == _generation) {
      return;
    }
    _updatedFor = _session.library;
    _generation = _session.generation;
    _update();
  }

  Future<void> _update() async {
    final lib = _session.library;
    final profile = _session.profile?.id;
    if (lib == null || profile == null || !await PlatformBridge.isTv()) return;
    final resume = await lib.continueWatching(
      kinds: [ItemKind.movie, ItemKind.episode],
      limit: 10,
    );
    final channels = await lib.recentChannels(limit: 10);
    if (!identical(lib, _session.library)) return;
    await PlatformBridge.updateTvHome(
      profile: profile,
      resume: [
        for (final r in resume)
          {
            ..._entry(r.item),
            'episode': r.item.kind == ItemKind.episode,
            'position': r.position,
            'duration': r.duration,
          },
      ],
      channels: [for (final c in channels) _entry(c)],
    );
  }

  static Map<String, Object?> _entry(ItemInfo i) => {
    'key': i.key,
    'title': i.name,
    'art': i.logo,
  };
}
