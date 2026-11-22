// A guide programme's sheet, from the guide grid and from search: title, episode, channel and time, genre, what can
// be watched (above the description, which can be long), and the description. Running: Watch (live) and, on catch-up
// channels, From the start. Past: Watch from the archive when the channel has one that reaches back far enough, else
// the channel live. Future: the channel live, and Remind me (a notification 5 minutes before the start; Reminders).
// Whether the archive reaches is the core's decision (Library.catchupUrl).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'browse_screen.dart';
import 'player_screen.dart';
import 'programme_text.dart';

Future<void> showProgrammeSheet(
  BuildContext context,
  Session session,
  ProgrammeInfo p,
  ItemInfo channel, {
  List<ItemInfo>? channels,
}) async {
  final l10n = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final running = p.start <= now && now < p.stop;
  final past = p.stop <= now;
  // Only asks whether there is a URL; it holds credentials and never leaves the session.
  final archive =
      session.library?.catchupUrl(
        key: channel.key,
        start: p.start,
        stop: p.stop,
      ) !=
      null;

  // Future programmes: whether a reminder is set (the core keeps them by channel and start).
  final future = p.start > now;
  var reminded =
      future &&
      ((await session.library?.reminders()) ?? const <ReminderInfo>[]).any(
        (r) => r.itemKey == channel.key && r.start == p.start,
      );
  if (!context.mounted) return;

  void live(BuildContext sheet) {
    Navigator.of(sheet).pop();
    openItem(context, session, channel, channels: channels);
  }

  Future<void> fromArchive(BuildContext sheet) async {
    Navigator.of(sheet).pop();
    if (!await session.playCatchup(channel, p) || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PlayerScreen(session: session, item: session.nowPlaying.value!),
      ),
    );
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) {
        final text = Theme.of(sheet).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Tokens.space * 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(p.title, style: text.titleLarge),
                if (p.subTitle.isNotEmpty || p.episode.isNotEmpty)
                  Text(
                    [
                      p.subTitle,
                      p.episode,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: text.titleSmall,
                  ),
                const SizedBox(height: Tokens.space),
                Text(
                  '${channel.name} · ${programmeWhen(l10n, locale, p)}',
                  style: text.bodyMedium,
                ),
                if (p.category.isNotEmpty)
                  Text(p.category, style: text.bodySmall),
                const SizedBox(height: Tokens.space * 2),
                Wrap(
                  spacing: Tokens.space,
                  runSpacing: Tokens.space,
                  children: [
                    if (past && archive)
                      FilledButton.icon(
                        key: const Key('programme.catchup'),
                        autofocus: true,
                        icon: const Icon(Icons.history),
                        label: Text(l10n.guideWatch),
                        onPressed: () => fromArchive(sheet),
                      )
                    else
                      FilledButton.icon(
                        key: const Key('guide.sheet.watch'),
                        autofocus: true,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                          running ? l10n.guideWatch : l10n.guideWatchChannel,
                        ),
                        onPressed: () => live(sheet),
                      ),
                    if (running && archive)
                      OutlinedButton.icon(
                        key: const Key('programme.fromStart'),
                        icon: const Icon(Icons.replay),
                        label: Text(l10n.programmeFromStart),
                        onPressed: () => fromArchive(sheet),
                      ),
                    if (future && session.library != null)
                      OutlinedButton.icon(
                        key: const Key('programme.remind'),
                        icon: Icon(
                          reminded
                              ? Icons.notifications_active
                              : Icons.notifications_none,
                        ),
                        label: Text(
                          reminded
                              ? l10n.programmeReminded
                              : l10n.programmeRemind,
                        ),
                        onPressed: () async {
                          final on = !reminded;
                          final r = ReminderInfo(
                            itemKey: channel.key,
                            start: p.start,
                            stop: p.stop,
                            title: p.title,
                          );
                          final reminders = session.reminders;
                          if (reminders != null) {
                            await reminders.set(
                              session.library!,
                              r,
                              channel.name,
                              on,
                            );
                          } else {
                            await session.library!.setReminder(
                              reminder: r,
                              on_: on,
                            );
                          }
                          setSheet(() => reminded = on);
                        },
                      ),
                  ],
                ),
                if (p.desc.isNotEmpty) ...[
                  const SizedBox(height: Tokens.space),
                  Text(p.desc, style: text.bodyMedium),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}
