// Settings → Playback → Audio and subtitles: the preferred languages and the subtitles' look, per profile. They apply
// from the next start (player/track_prefs.dart); the size and background the next time the player opens.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../player/track_prefs.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

class TrackPrefsSettings extends StatefulWidget {
  const TrackPrefsSettings({super.key, required this.library});
  final Library library;

  @override
  State<TrackPrefsSettings> createState() => _TrackPrefsSettingsState();
}

class _TrackPrefsSettingsState extends State<TrackPrefsSettings> {
  void _set(String key, String value) {
    widget.library.setSetting(key: key, value: value);
    setState(() {});
  }

  Widget _choice(String key, String title, Map<String, String> options) {
    final value = widget.library.setting(key: key) ?? '';
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<String>(
        key: Key('settings.$key'),
        value: options.containsKey(value) ? value : options.keys.first,
        onChanged: (v) => _set(key, v!),
        items: [
          for (final o in options.entries)
            DropdownMenuItem(value: o.key, child: Text(o.value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
          child: Text(
            l10n.playerTracks,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        _choice(settingAudioLanguage, l10n.audioLanguage, {
          '': l10n.trackAutomatic,
          ...trackLanguages,
        }),
        _choice(settingSubtitleLanguage, l10n.subtitleLanguage, {
          '': l10n.trackAutomatic,
          subtitlesOff: l10n.playerSubtitlesOff,
          ...trackLanguages,
        }),
        _choice(settingSubtitleSize, l10n.subtitleSize, {
          '100': '100 %',
          for (final p in subtitleSizes)
            if (p != 100) '$p': '$p %',
        }),
        SwitchListTile(
          key: const Key('settings.$settingSubtitleBackground'),
          title: Text(l10n.subtitleBackground),
          value: widget.library.setting(key: settingSubtitleBackground) != '0',
          onChanged: (on) => _set(settingSubtitleBackground, on ? '1' : '0'),
        ),
      ],
    );
  }
}
