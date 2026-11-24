// The now-playing bar: while a stream runs and the player screen is closed, it sits below every screen
// (MaterialApp.builder, so pushed lists don't cover it) with a live picture, the title, the watchdog's state and Stop. Tapping it opens the full player again without restarting the
// stream. Only Stop or another stream end playback (owner decision; docs/SPEC.md).

import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../theme.dart';
import 'player_screen.dart';

class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([session.nowPlaying, session.playerOpen]),
      builder: (context, _) {
        final item = session.nowPlaying.value;
        if (item == null || session.playerOpen.value) {
          return const SizedBox.shrink();
        }
        final adapter = session.adapter;
        return Material(
          key: const Key('nowPlaying.bar'),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: InkWell(
            onTap: () => session.navigatorKey.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(session: session, item: item),
              ),
            ),
            child: SizedBox(
              height: 72,
              child: Row(
                children: [
                  // The same video controller renders here and in the player: one stream, two views.
                  SizedBox(
                    width: 128,
                    child: playerVideo(
                      session.video,
                      controls: NoVideoControls,
                    ),
                  ),
                  const SizedBox(width: Tokens.space * 2),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        ValueListenableBuilder<String?>(
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
                                  return text == null
                                      ? const SizedBox.shrink()
                                      : Text(
                                          text,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        );
                                },
                              ),
                        ),
                      ],
                    ),
                  ),
                  // No tooltip: the bar lives outside the navigator's overlay, which tooltips need.
                  IconButton(
                    key: const Key('nowPlaying.stop'),
                    icon: Icon(Icons.stop, semanticLabel: l10n.stop),
                    onPressed: session.stopPlayback,
                  ),
                  const SizedBox(width: Tokens.space),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
