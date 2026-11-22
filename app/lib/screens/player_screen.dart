// Full-screen player: media_kit's video with a small overlay (title, back, stop, "Reconnecting (n)…", or the watchdog's
// failure message). The watchdog recovers by itself; the user never has to restart a channel.
// Leaving the screen keeps the stream playing (the now-playing bar takes over); only Stop or another stream end it.
// Picture mode (desktop: P or the mini-player button) shrinks the window to a floating, always-on-top mini player that
// shows only the picture, Restore and Stop; drag it anywhere. Android Picture-in-Picture uses the same mode.
// Keys: Esc/Back leaves (keeps playing; in picture mode it restores first), S stops, Space pauses, P mini player.

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
import 'buffer_picker.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.session, required this.item});
  final Session session;
  final ItemInfo item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _paused = false;
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
    });
  }

  /// Desktop: into the floating mini player and back. (Android/iOS Picture-in-Picture set pictureMode themselves.)
  void _toggleMini() {
    if (!isDesktop) return;
    final mini = !widget.session.pictureMode.value;
    mini ? _miniWindow.enter() : _miniWindow.exit();
    widget.session.pictureMode.value = mini;
  }

  void _back() {
    if (widget.session.pictureMode.value && isDesktop) {
      _toggleMini();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
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

  Future<void> _togglePause() async {
    final a = widget.session.adapter;
    _paused ? await a.resume() : await a.pause();
    setState(() => _paused = !_paused);
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
                        child: Video(
                          controller: widget.session.video,
                          controls: AdaptiveVideoControls,
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
                                  widget.item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
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
                      // Buffered seconds vs. the target (bottom left): the stream's cushion right now.
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

  /// Picture mode: only the video, with Restore and Stop; the whole picture drags the floating window (desktop).
  Widget _pictureOnly(AppLocalizations l10n) {
    final video = Video(
      controller: widget.session.video,
      controls: NoVideoControls,
    );
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
