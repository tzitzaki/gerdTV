// The system's Now Playing card (iOS lock screen and Control Center, Android media notification): what plays, with
// play/pause as its only control (owner decision). It follows the player every engine feeds (Session.player), so mpv
// and Apple's player show the same card. Sent on changes only: the system counts the position on by itself.
// The programme and the logo arrive later than the start; each completes the card when it is there.
// Debugging: no card on iOS means another app holds the audio session, or PlatformBridge.nowPlaying was never called.

import 'dart:async';

import '../src/rust/api/library.dart';
import '../src/rust/api/logos.dart';
import 'session.dart';

class MediaCard {
  MediaCard(this._session) {
    _session.nowPlaying.addListener(_onItem);
    _session.platform.onMediaCommand = (action) =>
        unawaited(_session.userPause(action == 'pause'));
  }

  final Session _session;
  ItemInfo? _item;
  String _programme = '';
  String? _artwork;
  Timer? _next;
  bool _watching = false;

  /// What the system believes the position is: [_at] when sent, counting on while playing.
  Duration _sent = Duration.zero;
  DateTime _at = DateTime(0);
  bool _playing = false;

  void _onItem() {
    final item = _session.nowPlaying.value;
    if (item?.key == _item?.key) return;
    _item = item;
    _programme = '';
    _artwork = null;
    _next?.cancel();
    if (item == null) {
      unawaited(_session.platform.clearNowPlaying());
      return;
    }
    _send();
    unawaited(_loadArtwork(item));
    if (item.kind == ItemKind.live) unawaited(_loadProgramme(item));
  }

  /// Called once the player exists (creating it starts mpv, so not before the first stream).
  void watch() {
    if (_watching) return;
    _watching = true;
    final s = _session.player.stream;
    s.playing.listen((_) => _send());
    s.duration.listen((_) => _send());
    // A jump (seek, resume): the position is elsewhere than the system counted to.
    s.position.listen((p) {
      final counted = _playing ? DateTime.now().difference(_at) : Duration.zero;
      if ((p - _sent - counted).inSeconds.abs() > 2 &&
          _item?.kind != ItemKind.live) {
        _send();
      }
    });
  }

  Future<void> _loadArtwork(ItemInfo item) async {
    if (item.logo.isEmpty) return;
    final file = await logoFile(url: item.logo);
    if (file == null || _item?.key != item.key) return;
    _artwork = file;
    _send();
  }

  /// The running programme, again when it ends (or in 5 min, when the guide has none yet).
  Future<void> _loadProgramme(ItemInfo item) async {
    final rows = await _session.library?.nowNext(keys: [item.key]);
    if (_item?.key != item.key) return;
    final now = rows?.firstOrNull?.now;
    final left = now == null
        ? 300
        : now.stop - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _next = Timer(
      Duration(seconds: left < 1 ? 1 : left),
      () => _loadProgramme(item),
    );
    if (_programme == (now?.title ?? '')) return;
    _programme = now?.title ?? '';
    _send();
  }

  void _send() {
    final item = _item;
    if (item == null) return;
    // No player yet right after the first start: playing, from 0.
    final state = _watching ? _session.player.state : null;
    _playing = state?.playing ?? true;
    _sent = state?.position ?? Duration.zero;
    _at = DateTime.now();
    final live = item.kind == ItemKind.live;
    unawaited(
      _session.platform.nowPlaying(
        title: item.name,
        subtitle: _programme,
        artwork: _artwork,
        playing: _playing,
        position: live ? 0 : _sent.inMilliseconds / 1000,
        duration: live ? 0 : (state?.duration.inMilliseconds ?? 0) / 1000,
        live: live,
      ),
    );
  }

  void dispose() {
    _next?.cancel();
    _session.nowPlaying.removeListener(_onItem);
  }
}
