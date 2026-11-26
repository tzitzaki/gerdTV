// The player's audio and subtitle choice (owner request: Xtream movies often carry several languages). mpv lists
// the stream's tracks (media_kit's player.stream.tracks; "auto" and "no" are mpv's own entries, not real tracks);
// the sheet shows the real ones with language, title and codec, subtitles also Off. The button shows only when there
// is a choice: more than one audio track, or any subtitle.
// Debugging: a stream whose languages are missing here has no language tags; mpv's track-list shows the same.

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../l10n/gen/app_localizations.dart';
import '../player/track_prefs.dart';
import '../src/rust/api/subtitles.dart';

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
  Future<void> Function({int? audioMs, int? subtitleMs})? onDelay,
  TrackDelays? delays,
  VoidCallback? onFind,
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
              // OpenSubtitles (with the user's key, for movies and episodes in mpv).
              if (onFind != null)
                ListTile(
                  key: const Key('track.find'),
                  leading: const Icon(Icons.search),
                  title: Text(l10n.subtitlesFind),
                  onTap: () => pick(onFind),
                ),
              if (onDelay != null && delays != null) ...[
                _DelayRow(
                  id: 'audio',
                  label: l10n.audioDelay,
                  value: delays.audio,
                  onChanged: (ms) => onDelay(audioMs: delays.audio = ms),
                ),
                if (subs.isNotEmpty)
                  _DelayRow(
                    id: 'subtitle',
                    label: l10n.subtitleDelay,
                    value: delays.subtitle,
                    onChanged: (ms) =>
                        onDelay(subtitleMs: delays.subtitle = ms),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// "Audio delay  −  100 ms  +": buttons rather than a slider, so a D-pad reaches them; the sheet stays open.
class _DelayRow extends StatefulWidget {
  const _DelayRow({
    required this.id,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String id;
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_DelayRow> createState() => _DelayRowState();
}

class _DelayRowState extends State<_DelayRow> {
  late int _ms = widget.value;

  void _step(int by) {
    setState(() => _ms += by);
    widget.onChanged(_ms);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      title: Text(widget.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('delay.${widget.id}.less'),
            tooltip: l10n.delayEarlier,
            icon: const Icon(Icons.remove),
            onPressed: () => _step(-50),
          ),
          Text('$_ms ms'),
          IconButton(
            key: Key('delay.${widget.id}.more'),
            tooltip: l10n.delayLater,
            icon: const Icon(Icons.add),
            onPressed: () => _step(50),
          ),
        ],
      ),
    );
  }
}

/// OpenSubtitles' results for what plays; a tap downloads one and shows it. Errors (the day's quota, a refused key)
/// show in the sheet as OpenSubtitles words them.
Future<void> showFoundSubtitles(
  BuildContext context, {
  required Future<List<SubtitleInfo>> found,
  required Future<void> Function(SubtitleInfo) onPick,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: FutureBuilder<List<SubtitleInfo>>(
        future: found,
        builder: (context, snap) {
          final list = snap.data;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    l10n.subtitlesFind,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (snap.hasError)
                  ListTile(title: Text('${snap.error}'))
                else if (list == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  )
                else if (list.isEmpty)
                  ListTile(title: Text(l10n.subtitlesNone))
                else
                  for (final s in list) _FoundRow(subtitle: s, onPick: onPick),
              ],
            ),
          );
        },
      ),
    );
  },
);

class _FoundRow extends StatefulWidget {
  const _FoundRow({required this.subtitle, required this.onPick});
  final SubtitleInfo subtitle;
  final Future<void> Function(SubtitleInfo) onPick;

  @override
  State<_FoundRow> createState() => _FoundRowState();
}

class _FoundRowState extends State<_FoundRow> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.subtitle;
    return ListTile(
      key: Key('found.${s.fileId}'),
      enabled: !_busy,
      title: Text(s.release, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _error ??
            [
              s.language,
              if (s.hearingImpaired) l10n.subtitlesHearingImpaired,
              if (s.translated) l10n.subtitlesTranslated,
            ].join(' · '),
      ),
      onTap: () async {
        setState(() => _busy = true);
        try {
          await widget.onPick(s);
          if (context.mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) setState(() => _error = '$e');
        }
        if (mounted) setState(() => _busy = false);
      },
    );
  }
}
