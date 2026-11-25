// Settings → Playback → Player: what plays (platform/engine.dart). Live TV player (iPhone, iPad, Mac): gerdTV's or
// Apple's; below it gerdTV's player version (media_kit's mpv or the newer own build, where it is bundled), hidden
// while Apple's player is chosen (owner decision). The hidden version stays stored: movies and the channels Apple's
// player can't play still use it. Both apply at the next start; the notice shows only when the choice differs from
// what runs now, and goes when it is picked back.

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/engine.dart';
import '../services/session.dart';
import '../theme.dart';

class PlayerSettings extends StatefulWidget {
  const PlayerSettings({super.key, required this.session, this.hasOwnEngine});
  final Session session;

  /// Whether gerdTV's own libmpv is installed; tests set it.
  final bool? hasOwnEngine;

  static bool get hasLivePlayer =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  State<PlayerSettings> createState() => _PlayerSettingsState();
}

class _PlayerSettingsState extends State<PlayerSettings> {
  String get _dir => widget.session.appDir!;

  void _picked(VoidCallback write) {
    final running = widget.session.runningPlayers; // before the first write
    setState(write);
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    final stored = (engine: readEngine(_dir), live: readLivePlayer(_dir));
    if (stored == running) return;
    messenger.showSnackBar(
      SnackBar(
        key: const Key('settings.restartNotice'),
        content: Text(AppLocalizations.of(context).restartToApply),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    widget.session.runningPlayers; // captured before anything can change it
    final live = readLivePlayer(_dir);
    final apple = PlayerSettings.hasLivePlayer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (apple)
          _group(
            title: l10n.livePlayer,
            value: live,
            onChanged: (v) => _picked(() => writeLivePlayer(_dir, v)),
            choices: [
              (
                LivePlayer.gerdtv,
                'settings.live.gerdtv',
                l10n.recommended(l10n.livePlayerGerdtv),
                l10n.livePlayerGerdtvHint,
              ),
              (
                LivePlayer.apple,
                'settings.live.apple',
                l10n.livePlayerApple,
                l10n.livePlayerAppleHint,
              ),
            ],
          ),
        if ((widget.hasOwnEngine ?? ownLibmpv() != null) &&
            !(apple && live == LivePlayer.apple))
          _group(
            title: l10n.playerEngine,
            value: readEngine(_dir),
            onChanged: (v) => _picked(() => writeEngine(_dir, v)),
            choices: [
              (
                PlayerEngine.standard,
                'settings.engine.standard',
                l10n.recommended(l10n.playerEngineStandard),
                l10n.playerEngineStandardHint,
              ),
              (
                PlayerEngine.gerdtv,
                'settings.engine.gerdtv',
                l10n.playerEngineGerdtv,
                l10n.playerEngineGerdtvHint,
              ),
            ],
          ),
      ],
    );
  }

  /// A titled group of radio rows: (value, key, label, one line about it).
  Widget _group<T>({
    required String title,
    required T value,
    required void Function(T) onChanged,
    required List<(T, String, String, String)> choices,
  }) => RadioGroup<T>(
    groupValue: value,
    onChanged: (v) {
      if (v != null && v != value) onChanged(v);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Tokens.space * 2,
            Tokens.space,
            Tokens.space * 2,
            0,
          ),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final (v, key, label, hint) in choices)
          RadioListTile<T>(
            key: Key(key),
            value: v,
            title: Text(label),
            subtitle: Text(hint),
          ),
      ],
    ),
  );
}
