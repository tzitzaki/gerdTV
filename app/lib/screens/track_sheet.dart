// The player's audio and subtitle choice (owner request: Xtream movies often carry several languages). mpv lists
// the stream's tracks (media_kit's player.stream.tracks; "auto" and "no" are mpv's own entries, not real tracks);
// the sheet shows the real ones with language, title and codec, subtitles also Off. The button shows only when there
// is a choice: more than one audio track, or any subtitle.
// Debugging: a stream whose languages are missing here has no language tags; mpv's track-list shows the same.

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../l10n/gen/app_localizations.dart';

/// The stream's own tracks (mpv's "auto" and "no" left out).
List<T> realTracks<T>(List<T> tracks, String Function(T) id) => [
  for (final t in tracks)
    if (id(t) != 'auto' && id(t) != 'no') t,
];

/// Whether the player has something to choose.
bool hasTrackChoice(Tracks t) =>
    realTracks(t.audio, (a) => a.id).length > 1 ||
    realTracks(t.subtitle, (s) => s.id).isNotEmpty;

/// "German · Stereo · aac", "English (Director's comment) · ac3", or "Track 2" when the stream names nothing.
String trackLabel(
  AppLocalizations l10n, {
  required int index,
  String? title,
  String? language,
  String? codec,
}) {
  final lang = language == null || language.isEmpty ? null : language;
  final name = [?lang, if (title != null && title.isNotEmpty) title];
  final head = name.isEmpty
      ? l10n.playerTrack(index + 1)
      : name.length == 1
      ? name.first
      : '${name[0]} (${name[1]})';
  return [head, if (codec != null && codec.isNotEmpty) codec].join(' · ');
}

/// The sheet: audio tracks, then subtitles with Off; a tap applies it at once and closes the sheet.
Future<void> showTrackSheet(
  BuildContext context, {
  required Tracks tracks,
  required Track current,
  required ValueChanged<AudioTrack> onAudio,
  required ValueChanged<SubtitleTrack> onSubtitle,
}) {
  final l10n = AppLocalizations.of(context);
  final audio = realTracks(tracks.audio, (a) => a.id);
  final subs = realTracks(tracks.subtitle, (s) => s.id);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      void pick(VoidCallback apply) {
        apply();
        Navigator.pop(context);
      }

      Widget heading(String text) => ListTile(
        title: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
      Widget row(Key key, String label, bool on, VoidCallback apply) =>
          ListTile(
            key: key,
            leading: Icon(on ? Icons.check : null),
            title: Text(label),
            selected: on,
            onTap: () => pick(apply),
          );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (audio.length > 1) ...[
                heading(l10n.playerAudio),
                for (final (i, a) in audio.indexed)
                  row(
                    Key('track.audio.${a.id}'),
                    trackLabel(
                      l10n,
                      index: i,
                      title: a.title,
                      language: a.language,
                      codec: a.codec,
                    ),
                    current.audio.id == a.id,
                    () => onAudio(a),
                  ),
              ],
              if (subs.isNotEmpty) ...[
                heading(l10n.playerSubtitles),
                row(
                  const Key('track.subtitle.no'),
                  l10n.playerSubtitlesOff,
                  current.subtitle.id == 'no',
                  () => onSubtitle(SubtitleTrack.no()),
                ),
                for (final (i, s) in subs.indexed)
                  row(
                    Key('track.subtitle.${s.id}'),
                    trackLabel(
                      l10n,
                      index: i,
                      title: s.title,
                      language: s.language,
                      codec: s.codec,
                    ),
                    current.subtitle.id == s.id,
                    () => onSubtitle(s),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
