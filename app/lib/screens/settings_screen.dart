// Settings: the account (update now, last sync, remove), playback, the TV guide, stream health, about.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
import '../src/rust/api/simple.dart';
import '../theme.dart';
import 'buffer_picker.dart';
import 'guide_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.session});
  final Session session;

  Future<void> _confirmRemove(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    // The one modal the design allows: confirming a destructive action.
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.settingsRemoveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.remove),
          ),
        ],
      ),
    );
    if (ok == true) await session.removeProfile();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final last = session.lastSync;
        return ListView(
          padding: const EdgeInsets.all(Tokens.space),
          children: [
            ListTile(
              title: Text(
                l10n.settingsAccount,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(session.profile?.name ?? ''),
              subtitle: Text(
                session.syncing
                    ? l10n.syncing
                    : session.syncError != null
                    ? l10n.syncFailed(session.syncError!)
                    : last == null
                    ? ''
                    : l10n.settingsLastSync(last.entries, last.categories),
              ),
            ),
            ListTile(
              key: const Key('settings.sync'),
              leading: const Icon(Icons.sync),
              title: Text(l10n.settingsSyncNow),
              enabled: !session.syncing,
              onTap: session.sync,
            ),
            ListTile(
              key: const Key('settings.remove'),
              leading: const Icon(Icons.logout),
              title: Text(l10n.settingsRemove),
              onTap: () => _confirmRemove(context),
            ),
            const Divider(),
            if (session.library != null) _PlaybackSettings(session: session),
            const Divider(),
            if (session.library != null) GuideSettings(session: session),
            const Divider(),
            ListTile(
              title: Text(
                l10n.settingsHealth,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FutureBuilder<List<HealthInfo>>(
              future: session.library?.health(limit: 50),
              builder: (context, snap) {
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return ListTile(title: Text(l10n.healthEmpty));
                }
                return Column(
                  children: [
                    for (final h in rows)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          h.recovered
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                        ),
                        title: Text(
                          h.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${DateTime.fromMillisecondsSinceEpoch(h.at * 1000).toLocal().toString().substring(0, 16)} · ${h.trigger} · '
                          '${h.recovered ? l10n.healthRecovered(h.attempts, h.secs) : l10n.healthFailed(h.attempts)}',
                        ),
                      ),
                  ],
                );
              },
            ),
            const Divider(),
            ListTile(
              title: Text(
                l10n.settingsAbout,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text(l10n.aboutVersion(coreVersion())),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(l10n.settingsLicences),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'gerdTV',
                applicationVersion: coreVersion(),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Settings → Playback: the profile's buffer preset, adaptive mode, and the timeshift window (pause/rewind live).
/// Stored as profile settings (user data); a channel's own buffer (set in the player) wins over the preset.
class _PlaybackSettings extends StatefulWidget {
  const _PlaybackSettings({required this.session});
  final Session session;

  @override
  State<_PlaybackSettings> createState() => _PlaybackSettingsState();
}

class _PlaybackSettingsState extends State<_PlaybackSettings> {
  Library get _lib => widget.session.library!;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preset = parseBuffer(
      key: _lib.setting(key: settingBuffer) ?? 'balanced',
    );
    final adaptive = _lib.setting(key: settingAdaptive) == '1';
    final shift =
        int.tryParse(_lib.setting(key: settingTimeshift) ?? '') ??
        defaultTimeshiftSeconds(desktop: isDesktop);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            l10n.settingsPlayback,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          title: Text(l10n.settingsBuffer),
          subtitle: Text(l10n.bufferHint),
        ),
        BufferPicker(
          value: preset,
          onChanged: (c) => setState(() {
            _lib.setSetting(
              key: settingBuffer,
              value: bufferKey(preset: c.preset, customSeconds: c.seconds),
            );
          }),
        ),
        SwitchListTile(
          key: const Key('settings.adaptive'),
          title: Text(l10n.adaptiveBuffer),
          subtitle: Text(l10n.adaptiveHint),
          value: adaptive,
          onChanged: (on) => setState(
            () => _lib.setSetting(key: settingAdaptive, value: on ? '1' : '0'),
          ),
        ),
        ListTile(
          title: Text(l10n.timeshift),
          trailing: DropdownButton<int>(
            key: const Key('settings.timeshift'),
            value: [0, 1800, 3600, 7200].contains(shift) ? shift : 3600,
            items: [
              DropdownMenuItem(value: 0, child: Text(l10n.timeshiftOff)),
              for (final m in [30, 60, 120])
                DropdownMenuItem(
                  value: m * 60,
                  child: Text(l10n.timeshiftMinutes(m)),
                ),
            ],
            onChanged: (v) => setState(
              () => _lib.setSetting(key: settingTimeshift, value: '${v ?? 0}'),
            ),
          ),
        ),
      ],
    );
  }
}
