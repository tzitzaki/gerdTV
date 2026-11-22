// Full-screen player: media_kit's video with a small overlay (title, back, stop, "Reconnecting (n)…", or the watchdog's
// failure message). The watchdog recovers by itself; the user never has to restart a channel.
// Leaving the screen keeps the stream playing (the now-playing bar takes over); only Stop or another stream end it.
// Keys: Esc/Back leaves (keeps playing), S stops, Space pauses.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.session, required this.item});
  final Session session;
  final ItemInfo item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _paused = false;

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

  @override
  void dispose() {
    // Leaving the screen does not stop the stream: the now-playing bar takes over (deferred, as in initState).
    final session = widget.session;
    scheduleMicrotask(() => session.playerOpen.value = false);
    super.dispose();
  }

  Future<void> _stop() async {
    await widget.session.stopPlayback();
    if (mounted) Navigator.of(context).maybePop();
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
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        const SingleActivator(LogicalKeyboardKey.keyS): _stop,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
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
                        onPressed: () => Navigator.of(context).maybePop(),
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
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(Tokens.space * 4),
                  child: ValueListenableBuilder<String?>(
                    valueListenable: adapter.failure,
                    builder: (context, failure, _) =>
                        ValueListenableBuilder<int>(
                          valueListenable: adapter.reconnecting,
                          builder: (context, attempt, _) {
                            final text =
                                failure ??
                                (attempt > 0
                                    ? l10n.playerReconnecting(attempt)
                                    : null);
                            if (text == null) return const SizedBox.shrink();
                            return Card(
                              key: const Key('player.notice'),
                              child: Padding(
                                padding: const EdgeInsets.all(Tokens.space * 2),
                                child: Text(text),
                              ),
                            );
                          },
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
