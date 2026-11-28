// Settings, in seven categories (owner decision): Streaming (the provider, Premiumize, Your data), TV guide, Services
// (TMDB, OpenSubtitles, Trakt, Simkl), Devices (Devices & sync, web player), Playback (with Stream health),
// Appearance, About (with Updates) (docs/SPEC.md, "Settings"). Inside a category each subcategory is a card, one
// open at a time (_SettingsCard).
// Wide windows (desktop, TV) show the categories on the left and the chosen one on the right; phones show the
// categories as a list that opens a page. A search field on top filters every entry of every category as you type
// (settings_model.dart) and shows the matches grouped by category.
// Debugging: entries are rebuilt from scratch on every session notification (_categories), so a setting that shows a
// stale value usually means its widget read the value once in initState instead of in build.

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/engine.dart';
import '../player/frame_rate.dart';
import '../player/picture.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
import '../src/rust/api/simple.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'buffer_picker.dart';
import 'guide_settings.dart';
import 'list_modes.dart';
import 'player_settings.dart';
import 'player_screen.dart' show bufferReadoutSetting, playerGesturesSetting;
import 'premiumize_screen.dart';
import 'recordings_screen.dart';
import 'subtitles_settings.dart';
import '../services/recordings.dart' show canRecord;
import 'track_prefs_settings.dart';
import 'track_settings.dart';
import '../services/tracking.dart';
import 'settings_model.dart';
import 'devices_screen.dart';
import 'web_player_screen.dart';
import 'setup_screen.dart';
import 'update_settings.dart';
import 'user_data_settings.dart';

/// What the provider says about the account, as the last sync stored it (gerdtv-core, SETTING_ACCOUNT_*): when it ends
/// and how many streams it plays at once. Empty before the first sync and for M3U, which tells neither.
String accountLine(
  AppLocalizations l10n, {
  required String? expires,
  required String? limit,
}) {
  final ends = int.tryParse(expires ?? '');
  final streams = int.tryParse(limit ?? '');
  return [
    if (ends != null)
      l10n.accountExpires(
        DateFormat.yMMMd(l10n.localeName)
            .format(DateTime.fromMillisecondsSinceEpoch(ends * 1000)),
      )
    else if (streams != null)
      l10n.accountNoExpiry,
    if (streams != null) l10n.accountStreams(streams),
  ].join(' · ');
}

/// TMDB's required notice (its API terms, "Attribution"), word for word: not translated.
const tmdbNotice =
    'This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.session, this.focus});
  final Session session;

  /// The settings search field's focus (the shell's Ctrl/Cmd+F and `/`).
  final FocusNode? focus;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _query = TextEditingController();
  String?
  _selected; // wide layout: the category shown on the right (null: the first)

  Session get session => widget.session;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

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

  /// The setup form: a new provider profile, or [edit]'s provider pre-filled (a new login replaces the old one only
  /// once it works).
  void _openSetup(BuildContext context, {ProfileInfo? edit}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SetupScreen(session: session, edit: edit),
        ),
      );

  /// The provider card's ⋮: what's needed now and then, not every day (owner decision). Keys stay the old tiles'
  /// (`settings.profileEdit`, `settings.profileAdd`, `settings.sync`, `settings.remove`).
  Widget _providerMenu(BuildContext context, AppLocalizations l10n) {
    PopupMenuItem<VoidCallback> item(
      String key,
      IconData icon,
      String text,
      VoidCallback action, {
      bool enabled = true,
    }) => PopupMenuItem(
      key: Key(key),
      value: action,
      enabled: enabled,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(text),
      ),
    );
    return PopupMenuButton<VoidCallback>(
      key: const Key('settings.providerMenu'),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (session.profile != null && session.hasProvider)
          item(
            'settings.profileEdit',
            Icons.edit_outlined,
            l10n.profileEdit,
            () => _openSetup(context, edit: session.profile),
          ),
        item(
          'settings.profileAdd',
          Icons.add,
          l10n.profileAdd,
          () => _openSetup(context),
        ),
        if (session.hasProvider)
          item(
            'settings.sync',
            Icons.sync,
            l10n.settingsSyncNow,
            session.sync,
            enabled: !session.syncing,
          ),
        item(
          'settings.remove',
          Icons.logout,
          l10n.settingsRemove,
          () => _confirmRemove(context),
        ),
      ],
    );
  }

  /// Every category with its entries. Profile settings (playback, guide, lists) need an open library; a category
  /// left without entries is dropped.
  List<SettingsCategory> _categories(AppLocalizations l10n) {
    final lib = session.library;
    final last = session.lastSync;
    // Account's subcategories: the provider (its name, else "Provider"), then each linked service.
    final provider = session.profile?.name.isNotEmpty == true
        ? session.profile!.name
        : l10n.settingsProvider;
    final all = [
      // Streaming: the services that play (the IPTV provider of the open profile, Premiumize), and the profile's
      // data. Rare provider actions (edit, add, update now, remove) sit in the provider card's ⋮ menu (owner
      // decision: only what's used often shows); the User-Agent is part of the edit form.
      SettingsCategory(
        id: 'streaming',
        icon: Icons.live_tv_outlined,
        title: l10n.settingsStreaming,
        entries: [
          SettingsEntry(
            id: 'profile',
            section: provider,
            title: session.profile?.name ?? '',
            // The menu's actions are found by their words too (they have no entry of their own).
            keywords: [
              l10n.settingsKeywordsAccount,
              l10n.settingsKeywordsUserAgent,
              l10n.settingsKeywordsRemove,
              l10n.profileEdit,
              l10n.profileAdd,
              l10n.settingsSyncNow,
              l10n.settingsRemove,
            ].join(' '),
            actions: (context) => _providerMenu(context, l10n),
            build: (_) {
              // The card's title is the provider's name: the tile only says how it's doing.
              final lines = [
                session.syncing
                    ? l10n.syncing
                    : session.syncError != null
                    ? l10n.syncFailed(session.syncError!)
                    : last == null
                    ? ''
                    : l10n.settingsLastSync(last.entries, last.categories),
                if (lib != null)
                  accountLine(
                    l10n,
                    expires: lib.setting(key: 'account_expires'),
                    limit: lib.setting(key: 'account_limit'),
                  ),
              ].where((s) => s.isNotEmpty).toList();
              if (lines.isEmpty) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(lines.first),
                subtitle: lines.length > 1
                    ? Text(lines.skip(1).join('\n'))
                    : null,
              );
            },
          ),
          // Profiles: switch to another provider account and whether this one opens without asking. Without a
          // provider, adding one is the point, so it shows here instead of only in the menu.
          SettingsEntry(
            id: 'profiles',
            section: provider,
            title: l10n.profiles,
            keywords: l10n.settingsKeywordsProfiles,
            build: (context) => StatefulBuilder(
              builder: (context, setState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!session.hasProvider)
                    ListTile(
                      key: const Key('settings.profileEdit'),
                      leading: const Icon(Icons.add),
                      title: Text(l10n.profileAddProvider),
                      onTap: () => _openSetup(context, edit: session.profile),
                    ),
                  for (final p in session.profiles)
                    if (p.id != session.profile?.id)
                      ListTile(
                        key: Key('settings.profile.${p.id}'),
                        leading: const Icon(Icons.swap_horiz),
                        title: Text(l10n.profileSwitch(p.name)),
                        onTap: () => session.openProfile(p),
                      ),
                  if (session.profiles.length > 1 && session.profile != null)
                    SwitchListTile(
                      key: const Key('settings.profileAlways'),
                      title: Text(l10n.profileAlways),
                      value: session.opensAlways(session.profile!),
                      onChanged: (on) => setState(() {
                        setAppSetting(
                          dir: session.appDir!,
                          key: Session.settingAlwaysProfile,
                          value: on ? session.profile!.id : '',
                        );
                      }),
                    ),
                ],
              ),
            ),
          ),
          if (lib != null)
            SettingsEntry(
              id: 'premiumize',
              section: l10n.premiumize,
              title: l10n.premiumize,
              keywords: l10n.settingsKeywordsPremiumize,
              build: (_) => PremiumizeSettings(session: session),
            ),
          // Your data: export and import the profile's user data (one JSON file).
          if (lib != null)
            SettingsEntry(
              id: 'userData',
              section: l10n.settingsYourData,
              title: l10n.userDataExport,
              keywords: l10n.settingsKeywordsData,
              build: (_) => UserDataSettings(session: session),
            ),
        ],
      ),
      SettingsCategory(
        id: 'guide',
        icon: Icons.calendar_view_week,
        title: l10n.settingsGuide,
        entries: [
          if (lib != null) ...[
            SettingsEntry(
              id: 'guideSources',
              section: l10n.settingsGuideSources,
              title: l10n.settingsGuideSources,
              keywords: l10n.settingsKeywordsGuideSources,
              build: (_) => GuideSources(session: session),
            ),
            SettingsEntry(
              id: 'guideOffset',
              section: l10n.guideOffset,
              title: l10n.guideOffset,
              keywords: l10n.settingsKeywordsOffset,
              build: (_) => GuideOffset(session: session),
            ),
            SettingsEntry(
              id: 'guideRefresh',
              section: l10n.settingsGuideSources,
              title: l10n.guideRefresh,
              build: (_) => GuideRefresh(session: session),
            ),
            SettingsEntry(
              id: 'guideUnmatched',
              section: l10n.guideUnmatched,
              title: l10n.guideUnmatched,
              keywords: l10n.settingsKeywordsUnmatched,
              build: (_) => GuideUnmatched(session: session),
            ),
          ],
        ],
      ),
      // Services that support playback: metadata, subtitles, watch tracking (each its own card).
      SettingsCategory(
        id: 'services',
        icon: Icons.extension_outlined,
        title: l10n.settingsServices,
        entries: [
          SettingsEntry(
            id: 'tmdb',
            section: 'TMDB',
            title: l10n.tmdbKey,
            keywords: l10n.settingsKeywordsTmdb,
            build: (_) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.space * 2,
                vertical: Tokens.space,
              ),
              child: TextFormField(
                key: const Key('settings.tmdbKey'),
                initialValue: session.tmdbKey ?? '',
                obscureText: true,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.tmdbKey,
                  helperText: l10n.tmdbKeyHint,
                  helperMaxLines: 4,
                ),
                onFieldSubmitted: session.setTmdbKey,
              ),
            ),
          ),
          SettingsEntry(
            id: 'opensubtitles',
            section: 'OpenSubtitles',
            title: l10n.subtitlesKey,
            keywords: l10n.settingsKeywordsSubtitles,
            build: (_) => SubtitlesSettings(session: session),
          ),
          if (lib != null)
            for (final t in trackServices)
              SettingsEntry(
                id: t.id,
                section: t.label,
                title: t.label,
                keywords: l10n.settingsKeywordsTracking,
                build: (_) => TrackSettings(session: session, service: t),
              ),
        ],
      ),
      // Everything between gerdTV installs: pairing and sync, the web player, and on macOS the menu bar mode.
      SettingsCategory(
        id: 'devices',
        icon: Icons.devices_outlined,
        title: l10n.settingsDevices,
        entries: [
          // Devices & sync: pair with and sync to other gerdTV installs (also without a provider: getting one is the
          // point then).
          SettingsEntry(
            id: 'devices',
            title: l10n.devicesTitle,
            keywords: l10n.settingsKeywordsDevices,
            build: (context) => ListTile(
              key: const Key('settings.devices'),
              leading: const Icon(Icons.devices),
              title: Text(l10n.devicesTitle),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DevicesScreen(session: session),
                ),
              ),
            ),
          ),
          // Web player: with a paired gerdTV host, login links for browsers and the open web sessions. Without one
          // the entry still shows, saying what's needed, and opens Devices & sync (it used to be hidden: hard to find).
          if (!session.devices.peers.value.any((p) => p.web.isNotEmpty))
            SettingsEntry(
              id: 'web',
              title: l10n.webTitle,
              keywords: l10n.settingsKeywordsWeb,
              build: (context) => ListTile(
                key: const Key('settings.web.none'),
                leading: const Icon(Icons.public),
                title: Text(l10n.webTitle),
                subtitle: Text(l10n.webNoHost),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DevicesScreen(session: session),
                  ),
                ),
              ),
            ),
          for (final host in session.devices.peers.value.where(
            (p) => p.web.isNotEmpty,
          ))
            SettingsEntry(
              id: 'web.${host.device.id}',
              title: l10n.webTitle,
              keywords: l10n.settingsKeywordsWeb,
              build: (context) => ListTile(
                key: Key('settings.web.${host.device.id}'),
                leading: const Icon(Icons.public),
                title: Text(l10n.webTitle),
                subtitle: Text(host.web),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WebPlayerScreen(session: session, host: host),
                  ),
                ),
              ),
            ),
          if (defaultTargetPlatform == TargetPlatform.macOS)
            SettingsEntry(
              id: 'menuBar',
              title: l10n.menuBar,
              keywords: l10n.menuBarHint,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.menuBar'),
                  title: Text(l10n.menuBar),
                  subtitle: Text(l10n.menuBarHint),
                  value: widget.session.menuBar,
                  onChanged: (on) async {
                    await widget.session.setMenuBar(on);
                    setState(() {});
                  },
                ),
              ),
            ),
        ],
      ),
      SettingsCategory(
        id: 'playback',
        icon: Icons.play_circle_outline,
        title: l10n.settingsPlayback,
        entries: [
          if (lib != null) ..._playbackEntries(l10n, lib),
          if (ownLibmpv() != null || PlayerSettings.hasLivePlayer)
            SettingsEntry(
              id: 'player',
              section: l10n.settingsPlayer,
              title: PlayerSettings.hasLivePlayer
                  ? l10n.livePlayer
                  : l10n.playerEngine,
              keywords:
                  '${l10n.settingsKeywordsEngine} ${l10n.settingsKeywordsLivePlayer}',
              build: (_) => PlayerSettings(session: session),
            ),
          // Touch screens only: desktop and TV have no swipes.
          if (lib != null && !isDesktop)
            SettingsEntry(
              id: 'gestures',
              section: l10n.settingsPlayer,
              title: l10n.playerGestures,
              keywords: l10n.settingsKeywordsGestures,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.gestures'),
                  title: Text(l10n.playerGestures),
                  subtitle: Text(l10n.playerGesturesHint),
                  value: lib.setting(key: playerGesturesSetting) != 'off',
                  onChanged: (on) {
                    lib.setSetting(
                      key: playerGesturesSetting,
                      value: on ? 'on' : 'off',
                    );
                    setState(() {});
                  },
                ),
              ),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'autoplayNext',
              section: l10n.settingsPlayer,
              title: l10n.autoplayNext,
              keywords: l10n.settingsKeywordsAutoplayNext,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.autoplayNext'),
                  title: Text(l10n.autoplayNext),
                  subtitle: Text(l10n.autoplayNextHint),
                  value: lib.setting(key: Session.settingAutoplayNext) != '0',
                  onChanged: (on) {
                    lib.setSetting(
                      key: Session.settingAutoplayNext,
                      value: on ? '1' : '0',
                    );
                    setState(() {});
                  },
                ),
              ),
            ),
          // Works on TVs only (phones report no modes), which the hint says.
          if (lib != null && defaultTargetPlatform == TargetPlatform.android)
            SettingsEntry(
              id: 'matchFrameRate',
              section: l10n.settingsPlayer,
              title: l10n.matchFrameRate,
              keywords: l10n.settingsKeywordsFrameRate,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.matchFrameRate'),
                  title: Text(l10n.matchFrameRate),
                  subtitle: Text(l10n.matchFrameRateHint),
                  value: lib.setting(key: settingMatchFrameRate) == '1',
                  onChanged: (on) {
                    lib.setSetting(
                      key: settingMatchFrameRate,
                      value: on ? '1' : '0',
                    );
                    setState(() {});
                  },
                ),
              ),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'deinterlace',
              section: l10n.settingsPlayer,
              title: l10n.deinterlace,
              keywords: l10n.settingsKeywordsDeinterlace,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.deinterlace'),
                  title: Text(l10n.deinterlace),
                  subtitle: Text(l10n.deinterlaceHint),
                  value: lib.setting(key: settingDeinterlace) == '1',
                  onChanged: (on) {
                    lib.setSetting(
                      key: settingDeinterlace,
                      value: on ? '1' : '0',
                    );
                    setState(() {});
                  },
                ),
              ),
            ),
          if (lib != null && canRecord)
            SettingsEntry(
              id: 'recordingsFolder',
              section: l10n.recordings,
              title: l10n.recordingsFolder,
              keywords: l10n.settingsKeywordsRecordings,
              build: (_) => RecordingsFolderSetting(session: session),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'tracks',
              section: l10n.playerTracks,
              title: l10n.playerTracks,
              keywords: l10n.settingsKeywordsTracks,
              build: (_) => TrackPrefsSettings(library: lib),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'bufferReadout',
              section: l10n.settingsBuffer,
              title: l10n.bufferReadoutShow,
              keywords: l10n.settingsKeywordsBuffer,
              build: (_) => StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  key: const Key('settings.bufferReadout'),
                  title: Text(l10n.bufferReadoutShow),
                  subtitle: Text(l10n.bufferReadoutShowHint),
                  value: lib.setting(key: bufferReadoutSetting) == 'on',
                  onChanged: (on) {
                    lib.setSetting(
                      key: bufferReadoutSetting,
                      value: on ? 'on' : 'off',
                    );
                    setState(() {});
                  },
                ),
              ),
            ),
          SettingsEntry(
            id: 'health',
            section: l10n.settingsHealth,
            title: l10n.settingsHealth,
            keywords: l10n.settingsKeywordsHealth,
            build: (_) => _HealthList(library: lib),
          ),
        ],
      ),
      SettingsCategory(
        id: 'appearance',
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearance,
        entries: [
          SettingsEntry(
            id: 'theme',
            section: l10n.settingsTheme,
            title: l10n.settingsTheme,
            keywords: l10n.settingsKeywordsTheme,
            build: (_) => _ThemeSettings(session: session),
          ),
          SettingsEntry(
            id: 'overlay',
            section:
                l10n.settingsTheme, // the banner's look belongs with the theme
            title: l10n.settingsOverlay,
            keywords: l10n.settingsKeywordsOverlay,
            build: (_) => _OverlaySettings(session: session),
          ),
          SettingsEntry(
            id: 'logo',
            section: l10n.settingsLogo,
            title: l10n.settingsLogo,
            keywords: l10n.settingsKeywordsLogo,
            build: (_) => _LogoPicker(session: session),
          ),
          if (lib != null)
            SettingsEntry(
              id: 'lists',
              section: l10n.settingsLists,
              title: l10n.settingsLists,
              keywords: l10n.settingsKeywordsLists,
              build: (_) => _ListSettings(session: session),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'hidden',
              section: l10n.settingsLists,
              title: l10n.hiddenGroups,
              keywords: l10n.settingsKeywordsHidden,
              build: (context) => ListTile(
                key: const Key('settings.hidden'),
                title: Text(l10n.hiddenGroups),
                subtitle: Text(l10n.hiddenGroupsHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HiddenGroupsScreen(session: session),
                  ),
                ),
              ),
            ),
        ],
      ),
      SettingsCategory(
        id: 'about',
        icon: Icons.info_outline,
        title: l10n.settingsAbout,
        entries: [
          SettingsEntry(
            id: 'version',
            title: l10n.aboutVersion(coreVersion()),
            build: (_) => ListTile(
              leading: AppLogoMark(logo: session.logo, size: 32),
              title: Text(l10n.aboutVersion(coreVersion())),
            ),
          ),
          SettingsEntry(
            id: 'updates',
            title: l10n.updateCheck,
            keywords: l10n.settingsKeywordsUpdates,
            build: (_) => UpdateSettings(session: session),
          ),
          // TMDB's terms: its logo, less prominent than gerdTV's, and its notice word for word.
          SettingsEntry(
            id: 'tmdbAttribution',
            title: 'TMDB',
            keywords: l10n.settingsKeywordsTmdb,
            build: (_) => ListTile(
              key: const Key('settings.tmdbAttribution'),
              title: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Image.asset('assets/tmdb/tmdb.png', height: 14),
              ),
              subtitle: const Text(tmdbNotice),
            ),
          ),
          SettingsEntry(
            id: 'licences',
            title: l10n.settingsLicences,
            keywords: l10n.settingsKeywordsLicences,
            build: (context) => ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(l10n.settingsLicences),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'gerdTV',
                applicationVersion: coreVersion(),
              ),
            ),
          ),
        ],
      ),
    ];
    return [
      for (final c in all)
        if (c.entries.isNotEmpty) c,
    ];
  }

  /// Settings → Playback: the profile's buffer preset, adaptive mode, and the timeshift window (pause/rewind live).
  /// Stored as profile settings (user data); a channel's own buffer (set in the player) wins over the preset.
  /// Each entry rebuilds itself after a change (StatefulBuilder): the session doesn't notify for settings.
  List<SettingsEntry> _playbackEntries(AppLocalizations l10n, Library lib) => [
    SettingsEntry(
      id: 'buffer',
      section: l10n.settingsBuffer,
      title: l10n.settingsBuffer,
      keywords: l10n.settingsKeywordsBuffer,
      build: (_) => StatefulBuilder(
        builder: (context, setState) {
          final preset = parseBuffer(
            key: lib.setting(key: settingBuffer) ?? 'balanced',
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The card's title says "Buffer": only the hint here.
              ListTile(subtitle: Text(l10n.bufferHint)),
              BufferPicker(
                value: preset,
                onChanged: (c) => setState(() {
                  lib.setSetting(
                    key: settingBuffer,
                    value: bufferKey(
                      preset: c.preset,
                      customSeconds: c.seconds,
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    ),
    SettingsEntry(
      id: 'adaptive',
      section: l10n.settingsBuffer,
      title: l10n.adaptiveBuffer,
      keywords: l10n.settingsKeywordsAdaptive,
      build: (_) => StatefulBuilder(
        builder: (context, setState) => SwitchListTile(
          key: const Key('settings.adaptive'),
          title: Text(l10n.adaptiveBuffer),
          subtitle: Text(l10n.adaptiveHint),
          value: lib.setting(key: settingAdaptive) == '1',
          onChanged: (on) => setState(
            () => lib.setSetting(key: settingAdaptive, value: on ? '1' : '0'),
          ),
        ),
      ),
    ),
    SettingsEntry(
      id: 'timeshift',
      section: l10n.settingsBuffer,
      title: l10n.timeshift,
      keywords: l10n.settingsKeywordsTimeshift,
      build: (_) => StatefulBuilder(
        builder: (context, setState) {
          final shift =
              int.tryParse(lib.setting(key: settingTimeshift) ?? '') ??
              defaultTimeshiftSeconds(desktop: isDesktop);
          return ListTile(
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
                () => lib.setSetting(key: settingTimeshift, value: '${v ?? 0}'),
              ),
            ),
          );
        },
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final search = Padding(
      padding: const EdgeInsets.all(Tokens.space),
      child: TextField(
        key: const Key('settings.search'),
        controller: _query,
        focusNode: widget.focus,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: l10n.settingsSearchHint,
          suffixIcon: _query.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.clear,
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_query.clear),
                ),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final categories = _categories(l10n);
        final searching = _query.text.trim().isNotEmpty;
        final matches = filterSettings(categories, _query.text);
        return Builder(
          builder: (context) {
            // The window's width, like the shell's rail/bar switch: beside the rail Settings gets less than 720 px.
            if (MediaQuery.sizeOf(context).width >= Tokens.wideLayout) {
              // Master-detail: categories left, the selected one (or the search results) right.
              final shown = searching ? matches : categories;
              final selected = categories.firstWhere(
                (x) => x.id == _selected,
                orElse: () => categories.first,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: Column(
                      children: [
                        search,
                        Expanded(
                          child: ListView(
                            children: [
                              for (final cat in shown)
                                _categoryTile(
                                  cat,
                                  selected: !searching && cat.id == selected.id,
                                  onTap: () => setState(() {
                                    _query.clear();
                                    _selected = cat.id;
                                  }),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: searching
                        ? _results(context, l10n, matches)
                        : _CategoryContent(
                            key: ValueKey(selected.id),
                            category: selected,
                          ),
                  ),
                ],
              );
            }
            // Phone: the categories (or the search results) in one list; a category opens its own page.
            return Column(
              children: [
                search,
                Expanded(
                  child: searching
                      ? _results(context, l10n, matches)
                      : ListView(
                          children: [
                            for (final cat in categories)
                              _categoryTile(
                                cat,
                                selected: false,
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _openCategory(context, cat.id),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _categoryTile(
    SettingsCategory cat, {
    required bool selected,
    Widget? trailing,
    required VoidCallback onTap,
  }) => ListTile(
    key: Key('settings.cat.${cat.id}'),
    leading: Icon(cat.icon),
    title: Text(cat.title),
    trailing: trailing,
    selected: selected,
    onTap: onTap,
  );

  /// Phone: a category's page. It rebuilds its entries from the session, so it stays live like the wide layout.
  void _openCategory(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            final l10n = AppLocalizations.of(context);
            final cats = _categories(l10n).where((c) => c.id == id);
            return Scaffold(
              appBar: AppBar(title: Text(cats.firstOrNull?.title ?? '')),
              body: cats.isEmpty
                  ? const SizedBox.shrink() // the account was removed meanwhile
                  : _CategoryContent(category: cats.first, header: false),
            );
          },
        ),
      ),
    );
  }

  /// The search results: matching entries under their category's label, every card open (nothing to fold while
  /// searching), or a line saying nothing matched.
  Widget _results(
    BuildContext context,
    AppLocalizations l10n,
    List<SettingsCategory> matches,
  ) {
    if (matches.isEmpty) {
      return ListView(
        key: const Key('settings.content'),
        children: [ListTile(title: Text(l10n.settingsNoMatch))],
      );
    }
    return ListView(
      key: const Key('settings.content'),
      padding: const EdgeInsets.only(bottom: Tokens.space * 2),
      children: [
        for (final cat in matches) ...[
          SectionLabel(cat.title),
          ..._cards(context, cat.entries, allOpen: true),
        ],
      ],
    );
  }
}

/// A category's entries: those without a section as they are, the others as one card per section, placed where the
/// section first appears. [open]: the open card's section; [allOpen]: the search's view, nothing folds.
List<Widget> _cards(
  BuildContext context,
  List<SettingsEntry> entries, {
  String? open,
  bool allOpen = false,
  ValueChanged<String>? onToggle,
}) {
  final bySection = <String, List<SettingsEntry>>{};
  for (final e in entries) {
    if (e.section != null) bySection.putIfAbsent(e.section!, () => []).add(e);
  }
  Widget entry(SettingsEntry e) =>
      KeyedSubtree(key: Key('settings.entry.${e.id}'), child: e.build(context));
  return [
    for (final e in entries)
      if (e.section == null)
        entry(e)
      else if (identical(bySection[e.section]!.first, e))
        _SettingsCard(
          title: e.section!,
          open: allOpen || e.section == open,
          onToggle: allOpen ? null : () => onToggle?.call(e.section!),
          actions: bySection[e.section]!
              .map((x) => x.actions)
              .nonNulls
              .firstOrNull
              ?.call(context),
          children: [for (final x in bySection[e.section]!) entry(x)],
        ),
  ];
}

/// One subcategory as a card: a header (its title, the section's actions, the fold arrow) and its entries. One card
/// is open at a time (owner decision), so the open one stands out: a raised surface and the title in the accent.
/// The header is one focusable tap target (Enter/OK folds it), so a remote walks card by card.
/// Debugging a card that doesn't open in a test: its header's key is `settings.section.<title>`.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.open,
    required this.onToggle,
    required this.actions,
    required this.children,
  });
  final String title;
  final bool open;
  final VoidCallback? onToggle; // null: always open (search results)
  final Widget? actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Tokens.motion;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.space,
        Tokens.space / 2,
        Tokens.space,
        Tokens.space / 2,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: open ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: Key('settings.section.$title'),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.space * 2,
                  Tokens.space,
                  Tokens.space,
                  Tokens.space,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: open ? scheme.primary : null,
                        ),
                      ),
                    ),
                    ?actions,
                    // Keeps the header's height when there's no arrow (search results).
                    SizedBox(
                      height: 40,
                      width: onToggle == null ? 0 : 40,
                      child: onToggle == null
                          ? null
                          : AnimatedRotation(
                              turns: open ? 0.5 : 0,
                              duration: motion,
                              child: const Icon(Icons.expand_more),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: motion,
              alignment: Alignment.topCenter,
              child: open
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: children,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// One category's entries, scrollable (key `settings.content`, which the integration tests scroll). The first card
/// starts open; opening another closes it, tapping the open one closes it too.
class _CategoryContent extends StatefulWidget {
  const _CategoryContent({
    super.key,
    required this.category,
    this.header = true,
  });
  final SettingsCategory category;
  final bool header; // the phone page has the title in its app bar

  @override
  State<_CategoryContent> createState() => _CategoryContentState();
}

class _CategoryContentState extends State<_CategoryContent> {
  String? _open; // the open card's section; null: the first one; '': none

  @override
  Widget build(BuildContext context) {
    final entries = widget.category.entries;
    final open = _open ?? entries.map((e) => e.section).nonNulls.firstOrNull;
    return ListView(
      key: const Key('settings.content'),
      padding: const EdgeInsets.only(bottom: Tokens.space * 2),
      children: [
        if (widget.header)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tokens.space * 2,
              Tokens.space * 2,
              Tokens.space * 2,
              Tokens.space,
            ),
            child: Text(
              widget.category.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          )
        else
          const SizedBox(height: Tokens.space / 2),
        ..._cards(
          context,
          entries,
          open: open,
          onToggle: (s) => setState(() => _open = s == open ? '' : s),
        ),
      ],
    );
  }
}

/// Settings → Playback → Stream health: the last 50 recoveries the watchdog made or gave up on.
class _HealthList extends StatelessWidget {
  const _HealthList({required this.library});
  final Library? library;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<List<HealthInfo>>(
      future: library?.health(limit: 50),
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
    );
  }
}

/// Settings → Appearance → Theme (owner decision): light, dark or the system's; the accent from [Tokens.accents];
/// neutral or accent-tinted surfaces; pure black for OLED screens (dark only). App-wide, applied at once.
class _ThemeSettings extends StatelessWidget {
  const _ThemeSettings({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final names = [
      l10n.accentOrange,
      l10n.accentRed,
      l10n.accentPink,
      l10n.accentViolet,
      l10n.accentBlue,
      l10n.accentTeal,
      l10n.accentGreen,
      l10n.accentGold,
    ];
    return ValueListenableBuilder<ThemePrefs>(
      valueListenable: session.theme,
      builder: (context, t, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              l10n.settingsTheme,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
            child: SegmentedButton<ThemeMode>(
              key: const Key('settings.themeMode'),
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text(l10n.themeSystem),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text(l10n.themeDark),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text(l10n.themeLight),
                ),
              ],
              selected: {t.mode},
              onSelectionChanged: (m) =>
                  session.setTheme(t.copyWith(mode: m.first)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Tokens.space * 2),
            child: Wrap(
              spacing: Tokens.space,
              runSpacing: Tokens.space,
              children: [
                for (var i = 0; i < Tokens.accents.length; i++)
                  _Swatch(
                    key: Key('settings.accent.$i'),
                    colour: Tokens.accents[i],
                    name: names[i],
                    selected: t.accent == i,
                    onTap: () => session.setTheme(t.copyWith(accent: i)),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            key: const Key('settings.tinted'),
            title: Text(l10n.themeTinted),
            subtitle: Text(l10n.themeTintedHint),
            value: t.tinted,
            onChanged: (v) => session.setTheme(t.copyWith(tinted: v)),
          ),
          SwitchListTile(
            key: const Key('settings.black'),
            title: Text(l10n.themeBlack),
            subtitle: Text(l10n.themeBlackHint),
            value: t.black,
            onChanged: t.mode == ThemeMode.light
                ? null
                : (v) => session.setTheme(t.copyWith(black: v)),
          ),
        ],
      ),
    );
  }
}

/// Settings → Appearance → Player banner: how much of the picture shows through it, in steps of 10 %.
class _OverlaySettings extends StatelessWidget {
  const _OverlaySettings({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: session.overlayTranslucency,
      builder: (context, percent, _) => ListTile(
        title: Text(l10n.settingsOverlay),
        subtitle: Slider(
          key: const Key('settings.overlay'),
          max: Session.maxOverlayTranslucency.toDouble(),
          divisions: Session.maxOverlayTranslucency ~/ 10,
          label: '$percent %',
          value: percent.toDouble(),
          onChanged: (v) => session.setOverlayTranslucency(v.round()),
        ),
        trailing: Text('$percent %'),
      ),
    );
  }
}

/// One accent colour to pick: a 40 px circle, ticked when chosen, reachable by keyboard and D-pad.
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.colour,
    required this.name,
    required this.selected,
    required this.onTap,
  });
  final Color colour;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: name,
      child: Semantics(
        selected: selected,
        button: true,
        label: name,
        child: InkResponse(
          onTap: onTap,
          radius: 26,
          child: AnimatedContainer(
            duration: Tokens.motion,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? ring : Colors.transparent,
                width: 3,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 20,
                    color:
                        ThemeData.estimateBrightnessForColor(colour) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// Settings → Appearance → Logo: the four mockups (app_logo.dart); picking one also switches the app icon.
class _LogoPicker extends StatelessWidget {
  const _LogoPicker({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final names = {
      AppLogo.gtv: l10n.logoGtv,
      AppLogo.screen: l10n.logoScreen,
      AppLogo.monogram: l10n.logoMonogram,
      AppLogo.signal: l10n.logoSignal,
    };
    return RadioGroup<AppLogo>(
      groupValue: session.logo,
      onChanged: (l) {
        if (l != null) session.setLogo(l);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              l10n.settingsLogo,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            subtitle: Text(l10n.settingsLogoHint),
          ),
          for (final logo in AppLogo.values)
            RadioListTile<AppLogo>(
              key: Key('settings.logo.${logo.name}'),
              value: logo,
              title: Text(names[logo]!),
              secondary: AppLogoMark(logo: logo, size: 40),
            ),
        ],
      ),
    );
  }
}

/// Settings → Appearance → Lists: each section's list mode (the list bar's toggle changes the same setting).
class _ListSettings extends StatefulWidget {
  const _ListSettings({required this.session});
  final Session session;

  @override
  State<_ListSettings> createState() => _ListSettingsState();
}

class _ListSettingsState extends State<_ListSettings> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lib = widget.session.library!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            l10n.settingsLists,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final (kind, name) in [
          (ItemKind.live, l10n.navLive),
          (ItemKind.movie, l10n.navMovies),
          (ItemKind.series, l10n.navSeries),
        ])
          ListTile(
            title: Text(name),
            trailing: DropdownButton<ListMode>(
              key: Key('settings.listMode.${kind.name}'),
              value: parseListMode(
                lib.setting(key: listModeSetting(kind)),
                kind,
              ),
              items: [
                for (final m in ListMode.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text(listModeLabel(l10n, m)),
                  ),
              ],
              onChanged: (m) => setState(
                () => lib.setSetting(
                  key: listModeSetting(kind),
                  value: (m ?? defaultListMode(kind)).name,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Settings → Appearance → Hidden groups: every group of Live TV, Movies and Series; a ticked one disappears from the
/// lists, search, the guide, favourites and continue watching (user data, kept across syncs by group id).
class HiddenGroupsScreen extends StatefulWidget {
  const HiddenGroupsScreen({super.key, required this.session});
  final Session session;

  @override
  State<HiddenGroupsScreen> createState() => _HiddenGroupsScreenState();
}

class _HiddenGroupsScreenState extends State<HiddenGroupsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lib = widget.session.library!;
    final sections = [
      (ItemKind.live, l10n.navLive),
      (ItemKind.movie, l10n.navMovies),
      (ItemKind.series, l10n.navSeries),
    ];
    return DefaultTabController(
      length: sections.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.hiddenGroups),
          bottom: TabBar(tabs: [for (final (_, n) in sections) Tab(text: n)]),
        ),
        body: TabBarView(
          children: [
            for (final (kind, _) in sections)
              FutureBuilder<List<GroupVisibility>>(
                // Re-read after each change (setState): the list is small.
                future: lib.allGroups(kind: kind),
                builder: (context, snap) {
                  final groups = snap.data;
                  if (groups == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView(
                    children: [
                      for (final g in groups)
                        CheckboxListTile(
                          key: Key('hidden.${kind.name}.${g.group.id}'),
                          title: Text(g.group.name),
                          subtitle: Text('${g.group.count}'),
                          value: g.hidden,
                          onChanged: (on) {
                            lib.setGroupHidden(
                              kind: kind,
                              category: g.group.id,
                              hidden: on ?? false,
                            );
                            widget.session.groupsChanged();
                            setState(() {});
                          },
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
