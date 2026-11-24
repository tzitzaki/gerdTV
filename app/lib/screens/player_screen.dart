// Full-screen player: media_kit's video with a small overlay (title, back, stop, "Reconnecting (n)…", or the watchdog's
// failure message). The watchdog recovers by itself; the user never has to restart a channel.
// Leaving the screen keeps the stream playing (the now-playing bar takes over); only Stop or another stream end it.
// Picture mode (desktop: P or the mini-player button) shrinks the window to a floating, always-on-top mini player that
// shows only the picture, Restore and Stop; drag it anywhere. Android Picture-in-Picture uses the same mode.
// Live channels opened from a group or the guide: Up/Down switch to the previous/next channel of that list, a banner
// shows what's on now and next (5 s after each start or switch, and on OK), OK opens the channel list beside the
// picture. media_kit's own controls keep Space, Left/Right (seek), J/I and F; their Up/Down (volume) and Esc are ours.
// Keys: Esc/Back leaves (keeps playing; it closes the channel list or restores picture mode first), S stops,
// Space pauses, P mini player, Up/Down channels, OK (Enter/Select) the channel list.
// Pause and rewind live (timeshift window > 0): the controls' seek bar spans the back buffer up to live; "−5:12" and
// Go live show at the top while behind live (live_edge.dart says where live is); Left/Right skip 10 s on phone and
// TV (the D-pad), 2 s on desktop as before.
// Touch (phones): media_kit's gestures, switchable in Settings → Playback (withGestures below).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:window_manager/window_manager.dart' show DragToMoveArea;

import '../l10n/gen/app_localizations.dart';
import '../platform/mini_window.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import '../player/live_edge.dart';
import 'buffer_picker.dart';
import 'list_modes.dart';

/// The profile setting for the player gestures: on unless "off" (Settings → Playback).
const playerGesturesSetting = 'player_gestures';

/// The player gestures on touch screens (owner decision; media_kit's own, so they work in fullscreen too):
/// - movies and episodes: a horizontal swipe seeks (the further, the more), a double tap on the left or right third
///   skips 10 s;
/// - everything: a vertical swipe on the right half sets the player's volume (mpv's 0–100 %, not the system's: iOS has
///   no public API for that).
/// Live channels don't seek by swipe: media_kit seeks against the stream's duration, which a live stream doesn't
/// have, and timeshift has its own bar and live edge. Off: none of them (the controls still work by tap).
MaterialVideoControlsThemeData withGestures(
  MaterialVideoControlsThemeData base, {
  required bool enabled,
  required bool vod,
  required double volume,
  required ValueChanged<double> onVolume,
}) => base.copyWith(
  seekGesture: enabled && vod,
  seekOnDoubleTap: enabled && vod,
  volumeGesture: enabled,
  brightnessGesture: false, // would need a platform channel; not asked for
  initialVolume: volume.clamp(0.0, 1.0),
  onVolumeChanged: onVolume,
);

/// Every video view of the one stream (player, picture mode, now-playing bar). media_kit pauses the player when the
/// app goes to the background unless told otherwise; gerdTV keeps playing (owner decision: playback ends only by
/// Stop), so the phone's lock screen, another app or iOS's hand-over to AVPlayer Picture-in-Picture don't pause it.
/// Debugging: sound stopping on lock with this in place points at the audio session (ios/Runner/AppDelegate.swift).
Video playerVideo(
  VideoController controller, {
  required VideoControlsBuilder? controls,
}) => Video(
  controller: controller,
  controls: controls,
  pauseUponEnteringBackgroundMode: false,
  resumeUponEnteringForegroundMode: false,
);

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.session, required this.item});
  final Session session;
  final ItemInfo item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _paused = false;

  /// What's on, for the banner (the playing channel) and the channel list (every channel of the list).
  bool _banner = false;
  Timer? _bannerTimer;
  bool _panel = false;
  final Map<String, NowNext> _nowNext = {};

  /// Timeshift: where live is, for the running channel ([_edgeKey]); a new channel starts a new edge.
  LiveEdge _edge = LiveEdge();
  String? _edgeKey;
  Timer? _shiftTick;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferSub;

  ItemInfo get _current => widget.session.nowPlaying.value ?? widget.item;
  List<ItemInfo> get _channels => widget.session.zapList;
  static final _miniWindow = MiniWindow();

  @override
  void initState() {
    super.initState();
    // Deferred: changing it here (during build) would rebuild the now-playing bar mid-build, which Flutter forbids.
    final session = widget.session;
    final item = widget.item;
    scheduleMicrotask(() {
      session.playerOpen.value = true;
      session.play(item); // sets nowPlaying, which the bar also listens to
      _showBanner();
    });
    // How far mpv's cache reaches (`demuxer-cache-time`, which media_kit observes itself): live while attached.
    _bufferSub = session.player.stream.buffer.listen(
      (b) => _liveEdge.cache(b.inMilliseconds / 1000, DateTime.now()),
    );
    _positionSub = session.player.stream.position.listen(
      (p) => _liveEdge.position(p.inMilliseconds / 1000),
    );
    // The "behind live" label counts up while paused or rewound.
    _shiftTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _shiftable) setState(() {});
    });
  }

  bool get _shiftable => widget.session.timeshiftWindow.value > 0;

  /// The edge of the running channel (reset when the channel changed: zapping keeps this screen).
  LiveEdge get _liveEdge {
    if (_edgeKey != _current.key) {
      _edgeKey = _current.key;
      _edge = LiveEdge();
    }
    return _edge;
  }

  double get _position =>
      widget.session.player.state.position.inMilliseconds / 1000;

  /// Seeks by [secs] inside the back buffer (never past live, never before its start); back means off live.
  Future<void> _shift(double secs) => _seekTo(_position + secs);

  Future<void> _seekTo(double target) async {
    final now = DateTime.now();
    final e = _liveEdge;
    final live = e.live(now);
    if (live == null) return;
    final to = target.clamp(
      e.earliest(widget.session.timeshiftWindow.value, now),
      live,
    );
    live - to < liveSlack ? e.attach() : e.detach();
    await widget.session.player.seek(
      Duration(milliseconds: (to * 1000).round()),
    );
    if (mounted) setState(() {});
  }

  /// Back to live: just short of the cache's end, playing (exactly at it, mpv has nothing left to play and waits for
  /// new data; half the live slack still counts as live).
  Future<void> _goLive() async {
    final live = _liveEdge.live(DateTime.now());
    if (live == null) return;
    // Never past what is cached: on a slow connection the projected live edge runs ahead of the data (macOS CI).
    final cached = widget.session.player.state.buffer.inMilliseconds / 1000;
    await _seekTo((cached < live ? cached : live) - liveSlack / 2);
    if (_paused) await _togglePause();
  }

  /// Shows the banner for 5 s with what's on now on the playing channel (live only).
  Future<void> _showBanner() async {
    final it = _current;
    if (it.kind != ItemKind.live || !mounted) return;
    _bannerTimer?.cancel();
    setState(() => _banner = true);
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _banner = false);
    });
    await _loadNowNext([it]);
  }

  Future<void> _loadNowNext(List<ItemInfo> items) async {
    final lib = widget.session.library;
    if (lib == null || items.isEmpty) return;
    final keys = [for (final i in items) i.key];
    final rows = await lib.nowNext(keys: keys);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < keys.length; i++) {
        _nowNext[keys[i]] = rows[i];
      }
    });
  }

  /// Up/Down: the previous/next channel of the list it was opened from (wrapping around).
  Future<void> _zap(int delta) async {
    final list = _channels;
    final i = list.indexWhere((c) => c.key == _current.key);
    if (list.length < 2 || i < 0) return;
    await _switchTo(list[(i + delta + list.length) % list.length]);
  }

  Future<void> _switchTo(ItemInfo channel) async {
    await widget.session.play(channel);
    await _showBanner();
  }

  void _togglePanel() {
    if (_channels.length < 2) {
      _showBanner();
      return;
    }
    setState(() => _panel = !_panel);
    if (_panel) _loadNowNext(_channels);
  }

  /// Desktop: into the floating mini player and back. (Android/iOS Picture-in-Picture set pictureMode themselves.)
  void _toggleMini() {
    if (!isDesktop) return;
    final mini = !widget.session.pictureMode.value;
    mini ? _miniWindow.enter() : _miniWindow.exit();
    widget.session.pictureMode.value = mini;
  }

  void _back() {
    if (_panel) {
      setState(() => _panel = false);
      return;
    }
    if (widget.session.pictureMode.value && isDesktop) {
      _toggleMini();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _shiftTick?.cancel();
    _positionSub?.cancel();
    _bufferSub?.cancel();
    if (_miniWindow.isMini) {
      _miniWindow.exit();
      widget.session.pictureMode.value = false;
    }
    // Leaving the screen does not stop the stream: the now-playing bar takes over (deferred, as in initState).
    final session = widget.session;
    scheduleMicrotask(() => session.playerOpen.value = false);
    super.dispose();
  }

  Future<void> _stop() async {
    await widget.session.stopPlayback();
    if (mounted) Navigator.of(context).maybePop();
  }

  /// "Buffer for this channel": the channel's own preset (or back to the default), applied to the running stream.
  Future<void> _bufferSheet() async {
    final lib = widget.session.library;
    if (lib == null) return;
    final key = widget.item.key;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return StatefulBuilder(
          builder: (context, setSheet) {
            final current = lib.bufferFor(key: key);
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: Text(
                        l10n.bufferThisChannel,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    BufferPicker(
                      value: current,
                      onChanged: (c) {
                        lib.setChannelBuffer(
                          key: key,
                          preset: c.preset,
                          customSeconds: c.seconds,
                        );
                        widget.session.adapter.applyBuffer(c.preset, c.seconds);
                        setSheet(() {});
                      },
                    ),
                    if (lib.hasChannelBuffer(key: key))
                      TextButton(
                        key: const Key('buffer.default'),
                        onPressed: () {
                          lib.setChannelBuffer(
                            key: key,
                            preset: null,
                            customSeconds: 0,
                          );
                          final d = lib.bufferFor(key: key);
                          widget.session.adapter.applyBuffer(
                            d.preset,
                            d.seconds,
                          );
                          setSheet(() {});
                        },
                        child: Text(
                          '${l10n.bufferUseDefault} (${presetLabel(l10n, lib.bufferFor(key: key))})',
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// media_kit's desktop controls without their Up/Down (volume) and Esc, which switch channels and leave here.
  /// With timeshift, our seek bar over the back buffer replaces theirs (a live stream has no duration to show).
  MaterialDesktopVideoControlsThemeData get _desktopControls {
    final p = widget.session.player;
    void seek(int secs) => _shiftable
        ? _shift(secs.toDouble())
        : p.seek(p.state.position + Duration(seconds: secs));
    return MaterialDesktopVideoControlsThemeData(
      displaySeekBar: !_shiftable,
      bottomButtonBar: _shiftable
          ? [
              _pauseButton(desktop: true),
              Expanded(child: _timeshiftBar()),
              const MaterialDesktopVolumeButton(),
              const MaterialDesktopFullscreenButton(),
            ]
          : kDefaultMaterialDesktopVideoControlsThemeData.bottomButtonBar,
      keyboardShortcuts: {
        // Ours, not media_kit's playOrPause: only a pause by the user moves timeshift off live (media_kit reports
        // "not playing" at every stream start too), and the watchdog must know a pause isn't a stall.
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _togglePause,
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => seek(-2),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => seek(2),
        const SingleActivator(LogicalKeyboardKey.keyJ): () => seek(-10),
        const SingleActivator(LogicalKeyboardKey.keyI): () => seek(10),
      },
    );
  }

  /// Phone and TV controls, the same change, plus the player gestures (Settings → Playback).
  MaterialVideoControlsThemeData get _mobileControls {
    final p = widget.session.player;
    return withGestures(
      _shiftable
          ? MaterialVideoControlsThemeData(
              displaySeekBar: false,
              primaryButtonBar: [
                const Spacer(),
                _pauseButton(desktop: false),
                const Spacer(),
              ],
              bottomButtonBar: [
                Expanded(child: _timeshiftBar()),
                const MaterialFullscreenButton(),
              ],
            )
          : kDefaultMaterialVideoControlsThemeData,
      enabled:
          widget.session.library?.setting(key: playerGesturesSetting) != 'off',
      vod: _current.kind != ItemKind.live,
      volume: p.state.volume / 100,
      onVolume: (v) => p.setVolume(v * 100),
    );
  }

  /// The seek bar over the back buffer: from the window's start (or the stream's) to live.
  Widget _timeshiftBar() {
    final now = DateTime.now();
    final e = _liveEdge;
    final live = e.live(now) ?? _position;
    final from = e.earliest(widget.session.timeshiftWindow.value, now);
    return Slider(
      key: const Key('player.timeshift'),
      min: from,
      max: live > from ? live : from + 1,
      value: _position.clamp(from, live > from ? live : from + 1),
      onChanged: (v) => _seekTo(v),
    );
  }

  Future<void> _togglePause() async {
    final a = widget.session.adapter;
    if (!_paused && _shiftable) {
      _liveEdge.detach(); // paused: live moves on without us
    }
    _paused ? await a.resume() : await a.pause();
    setState(() => _paused = !_paused);
  }

  /// Play/pause in the controls while timeshift is on: ours (see the keyboard shortcuts above).
  Widget _pauseButton({required bool desktop}) {
    final icon = Icon(_paused ? Icons.play_arrow : Icons.pause);
    return desktop
        ? MaterialDesktopCustomButton(
            key: const Key('player.pause'),
            icon: icon,
            onPressed: _togglePause,
          )
        : MaterialCustomButton(
            key: const Key('player.pause'),
            icon: icon,
            iconSize: 48,
            onPressed: _togglePause,
          );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final adapter = widget.session.adapter;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _back,
        const SingleActivator(LogicalKeyboardKey.keyP): _toggleMini,
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        const SingleActivator(LogicalKeyboardKey.keyS): _stop,
        // Only while the channel list is closed: inside it these keys move the focus and pick a channel.
        if (!_panel) ...{
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _zap(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _zap(1),
          const SingleActivator(LogicalKeyboardKey.enter): _togglePanel,
          const SingleActivator(LogicalKeyboardKey.select): _togglePanel,
          // The D-pad on TV (and arrow keys on phones): 10 s per press; desktop keeps media_kit's 2 s.
          if (_shiftable && !isDesktop) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _shift(-10),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _shift(10),
          },
        },
      },
      child: Focus(
        autofocus: true,
        child: ValueListenableBuilder<bool>(
          valueListenable: widget.session.pictureMode,
          builder: (context, picture, _) => picture
              ? _pictureOnly(l10n)
              : Scaffold(
                  backgroundColor: Colors.black,
                  body: Stack(
                    children: [
                      Positioned.fill(
                        child: MaterialVideoControlsTheme(
                          normal: _mobileControls,
                          fullscreen: _mobileControls,
                          child: MaterialDesktopVideoControlsTheme(
                            normal: _desktopControls,
                            fullscreen: _desktopControls,
                            child: playerVideo(
                              widget.session.video,
                              controls: AdaptiveVideoControls,
                            ),
                          ),
                        ),
                      ),
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(Tokens.space),
                          child: Row(
                            children: [
                              IconButton.filledTonal(
                                key: const Key('player.back'),
                                tooltip: l10n.back,
                                icon: const Icon(Icons.arrow_back),
                                onPressed: _back,
                              ),
                              const SizedBox(width: Tokens.space),
                              Expanded(
                                child: Text(
                                  _current.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
                              ..._behindLive(l10n),
                              if (isDesktop) ...[
                                IconButton.filledTonal(
                                  key: const Key('player.mini'),
                                  tooltip: l10n.miniPlayer,
                                  icon: const Icon(
                                    Icons.picture_in_picture_alt,
                                  ),
                                  onPressed: _toggleMini,
                                ),
                                const SizedBox(width: Tokens.space),
                              ],
                              IconButton.filledTonal(
                                key: const Key('player.buffer'),
                                tooltip: l10n.bufferThisChannel,
                                icon: const Icon(Icons.tune),
                                onPressed: _bufferSheet,
                              ),
                              const SizedBox(width: Tokens.space),
                              if (isApple) ...[
                                IconButton.filledTonal(
                                  key: const Key('player.applePip'),
                                  tooltip: l10n.miniPlayer,
                                  icon: const Icon(
                                    Icons.picture_in_picture_alt,
                                  ),
                                  onPressed: widget.session.startApplePip,
                                ),
                                const SizedBox(width: Tokens.space),
                              ],
                              IconButton.filledTonal(
                                key: const Key('player.stop'),
                                tooltip: l10n.stop,
                                icon: const Icon(Icons.stop),
                                onPressed: _stop,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_banner && !_panel)
                        Positioned(
                          top: 72,
                          left: Tokens.space * 2,
                          right: Tokens.space * 2,
                          child: _NowNextBanner(
                            channel: _current,
                            nowNext: _nowNext[_current.key],
                            showHint: _channels.length > 1,
                          ),
                        ),
                      if (_panel)
                        Positioned(
                          top: 72,
                          bottom: Tokens.space * 2,
                          right: Tokens.space * 2,
                          width: 360,
                          child: _ChannelPanel(
                            channels: _channels,
                            current: _current,
                            nowNext: _nowNext,
                            onPick: (c) {
                              setState(() => _panel = false);
                              _switchTo(c);
                            },
                          ),
                        ),
                      // Buffered seconds vs. the target (bottom left): the stream's cushion right now. Hidden under the
                      // channel list, which reaches that corner on a phone (the screen check found them overlapping).
                      if (!_panel)
                        Positioned(
                          left: Tokens.space * 2,
                          bottom: Tokens.space * 2,
                          child: StreamBuilder<Duration>(
                            stream: widget.session.player.stream.buffer,
                            builder: (context, snap) {
                              final buffered =
                                  ((snap.data ?? Duration.zero) -
                                          widget.session.player.state.position)
                                      .inSeconds;
                              return ValueListenableBuilder<int>(
                                valueListenable: adapter.target,
                                builder: (context, target, _) => Text(
                                  l10n.bufferReadout(
                                    buffered < 0 ? 0 : buffered,
                                    target,
                                  ),
                                  key: const Key('player.bufferReadout'),
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(color: Colors.white70),
                                ),
                              );
                            },
                          ),
                        ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(Tokens.space * 4),
                          child: ListenableBuilder(
                            listenable: Listenable.merge([
                              adapter.failure,
                              adapter.reconnecting,
                              widget.session.bufferRaisedTo,
                            ]),
                            builder: (context, _) {
                              final failure = adapter.failure.value;
                              final attempt = adapter.reconnecting.value;
                              final raised =
                                  widget.session.bufferRaisedTo.value;
                              return Builder(
                                builder: (context) {
                                  final text =
                                      failure ??
                                      (attempt > 0
                                          ? l10n.playerReconnecting(attempt)
                                          : raised != null
                                          ? l10n.bufferRaised(raised)
                                          : null);
                                  if (text == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return Card(
                                    key: const Key('player.notice'),
                                    child: Padding(
                                      padding: const EdgeInsets.all(
                                        Tokens.space * 2,
                                      ),
                                      child: Text(text),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// While behind live: how far ("−5:12") and Go live (reachable with the D-pad).
  List<Widget> _behindLive(AppLocalizations l10n) {
    final behind = _shiftable ? _liveEdge.behind(_position, DateTime.now()) : 0;
    if (behind == 0) return const [];
    return [
      Text(
        behindLabel(behind),
        key: const Key('player.behind'),
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(color: Colors.white),
      ),
      const SizedBox(width: Tokens.space),
      FilledButton.tonalIcon(
        key: const Key('player.live'),
        onPressed: _goLive,
        icon: const Icon(Icons.skip_next),
        label: Text(l10n.goLive),
      ),
      const SizedBox(width: Tokens.space),
    ];
  }

  /// Picture mode: only the video, with Restore and Stop; the whole picture drags the floating window (desktop).
  Widget _pictureOnly(AppLocalizations l10n) {
    final video = playerVideo(widget.session.video, controls: NoVideoControls);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: isDesktop ? DragToMoveArea(child: video) : video,
          ),
          if (isDesktop)
            Positioned(
              top: Tokens.space,
              right: Tokens.space,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    key: const Key('player.restore'),
                    tooltip: l10n.restore,
                    icon: const Icon(Icons.open_in_full),
                    onPressed: _toggleMini,
                  ),
                  const SizedBox(width: Tokens.space),
                  IconButton.filledTonal(
                    tooltip: l10n.stop,
                    icon: const Icon(Icons.stop),
                    onPressed: () async {
                      _toggleMini();
                      await _stop();
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What's on now (with progress) and next on the playing channel.
class _NowNextBanner extends StatelessWidget {
  const _NowNextBanner({
    required this.channel,
    required this.nowNext,
    required this.showHint,
  });
  final ItemInfo channel;
  final NowNext? nowNext;
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final now = nowNext?.now;
    final next = nowNext?.next;
    return Card(
      key: const Key('player.banner'),
      child: Padding(
        padding: const EdgeInsets.all(Tokens.space * 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleMedium,
            ),
            if (now != null) ...[
              const SizedBox(height: Tokens.space / 2),
              Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Tokens.space / 2),
              LinearProgressIndicator(
                value: progressOf(now, DateTime.now()),
                minHeight: 3,
              ),
            ],
            if (next != null)
              Padding(
                padding: const EdgeInsets.only(top: Tokens.space / 2),
                child: Text(
                  l10n.playerNext(next.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ),
            if (showHint)
              Padding(
                padding: const EdgeInsets.only(top: Tokens.space / 2),
                child: Text(l10n.playerZapHint, style: text.labelSmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// The channel list beside the picture: each channel with what's on now; the playing one is selected and focused.
class _ChannelPanel extends StatefulWidget {
  const _ChannelPanel({
    required this.channels,
    required this.current,
    required this.nowNext,
    required this.onPick,
  });
  final List<ItemInfo> channels;
  final ItemInfo current;
  final Map<String, NowNext> nowNext;
  final void Function(ItemInfo) onPick;

  @override
  State<_ChannelPanel> createState() => _ChannelPanelState();
}

class _ChannelPanelState extends State<_ChannelPanel> {
  // Created once (opens at the playing channel), so a rebuild after now/next loads keeps the scroll position.
  late final _scroll = ScrollController(
    initialScrollOffset:
        widget.channels
            .indexWhere((c) => c.key == widget.current.key)
            .clamp(0, 1 << 30) *
        64.0,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final channels = widget.channels;
    final current = widget.current;
    final nowNext = widget.nowNext;
    return Card(
      key: const Key('player.panel'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            title: Text(
              l10n.playerChannels,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: 64,
              itemCount: channels.length,
              itemBuilder: (context, i) {
                final c = channels[i];
                return ListTile(
                  key: Key('player.panel.${c.key}'),
                  autofocus: c.key == current.key,
                  selected: c.key == current.key,
                  title: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    nowNext[c.key]?.now?.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => widget.onPick(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
