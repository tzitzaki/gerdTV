// Settings, in five categories (owner decision): Account (with Your data), Playback (with Stream health), TV guide,
// Appearance, About (with Updates) (docs/SPEC.md, "Settings").
// Wide windows (desktop, TV) show the categories on the left and the chosen one on the right; phones show the
// categories as a list that opens a page. A search field on top filters every entry of every category as you type
// (settings_model.dart) and shows the matches grouped by category.
// Debugging: entries are rebuilt from scratch on every session notification (_categories), so a setting that shows a
// stale value usually means its widget read the value once in initState instead of in build.

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/engine.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
import '../src/rust/api/simple.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'buffer_picker.dart';
import 'guide_settings.dart';
import 'list_modes.dart';
import 'player_screen.dart' show playerGesturesSetting;
import 'premiumize_screen.dart';
import 'track_settings.dart';
import '../services/tracking.dart';
import 'settings_model.dart';
import 'setup_screen.dart';
import 'update_settings.dart';
import 'user_data_settings.dart';

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
      SettingsCategory(
        id: 'account',
        icon: Icons.account_circle_outlined,
        title: l10n.settingsAccount,
        entries: [
          SettingsEntry(
            id: 'profile',
            section: provider,
            title: session.profile?.name ?? '',
            keywords: l10n.settingsKeywordsAccount,
            build: (_) => ListTile(
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
          ),
          // Profiles: switch to another provider account, add one, and whether this one opens without asking.
          SettingsEntry(
            id: 'profiles',
            section: provider,
            title: l10n.profiles,
            keywords: l10n.settingsKeywordsProfiles,
            build: (context) => StatefulBuilder(
              builder: (context, setState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  ListTile(
                    key: const Key('settings.profileAdd'),
                    leading: const Icon(Icons.add),
                    title: Text(l10n.profileAdd),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SetupScreen(session: session),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingsEntry(
            id: 'sync',
            section: provider,
            title: l10n.settingsSyncNow,
            keywords: l10n.settingsKeywordsAccount,
            build: (_) => ListTile(
              key: const Key('settings.sync'),
              leading: const Icon(Icons.sync),
              title: Text(l10n.settingsSyncNow),
              enabled: !session.syncing,
              onTap: session.sync,
            ),
          ),
          // Your data: export and import the profile's user data (one JSON file).
          if (lib != null)
            SettingsEntry(
              id: 'userData',
              section: provider,
              title: l10n.userDataExport,
              keywords: l10n.settingsKeywordsData,
              build: (_) => UserDataSettings(session: session),
            ),
          SettingsEntry(
            id: 'remove',
            section: provider,
            title: l10n.settingsRemove,
            keywords: l10n.settingsKeywordsRemove,
            build: (context) => ListTile(
              key: const Key('settings.remove'),
              leading: const Icon(Icons.logout),
              title: Text(l10n.settingsRemove),
              onTap: () => _confirmRemove(context),
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
      SettingsCategory(
        id: 'playback',
        icon: Icons.play_circle_outline,
        title: l10n.settingsPlayback,
        entries: [
          if (lib != null) ..._playbackEntries(l10n, lib),
          if (ownLibmpv() != null) _engineEntry(l10n),
          // Touch screens only: desktop and TV have no swipes.
          if (lib != null && !isDesktop)
            SettingsEntry(
              id: 'gestures',
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
          SettingsEntry(
            id: 'health',
            title: l10n.settingsHealth,
            keywords: l10n.settingsKeywordsHealth,
            build: (_) => _HealthList(library: lib),
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
              title: l10n.settingsGuideSources,
              keywords: l10n.settingsKeywordsGuideSources,
              build: (_) => GuideSources(session: session),
            ),
            SettingsEntry(
              id: 'guideOffset',
              title: l10n.guideOffset,
              keywords: l10n.settingsKeywordsOffset,
              build: (_) => GuideOffset(session: session),
            ),
            SettingsEntry(
              id: 'guideRefresh',
              title: l10n.guideRefresh,
              build: (_) => GuideRefresh(session: session),
            ),
            SettingsEntry(
              id: 'guideUnmatched',
              title: l10n.guideUnmatched,
              keywords: l10n.settingsKeywordsUnmatched,
              build: (_) => GuideUnmatched(session: session),
            ),
          ],
        ],
      ),
      SettingsCategory(
        id: 'appearance',
        icon: Icons.palette_outlined,
        title: l10n.settingsAppearance,
        entries: [
          SettingsEntry(
            id: 'theme',
            title: l10n.settingsTheme,
            keywords: l10n.settingsKeywordsTheme,
            build: (_) => _ThemeSettings(session: session),
          ),
          SettingsEntry(
            id: 'logo',
            title: l10n.settingsLogo,
            keywords: l10n.settingsKeywordsLogo,
            build: (_) => _LogoPicker(session: session),
          ),
          if (lib != null)
            SettingsEntry(
              id: 'lists',
              title: l10n.settingsLists,
              keywords: l10n.settingsKeywordsLists,
              build: (_) => _ListSettings(session: session),
            ),
          if (lib != null)
            SettingsEntry(
              id: 'hidden',
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
            build: (_) => const UpdateSettings(),
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
              ListTile(
                title: Text(l10n.settingsBuffer),
                subtitle: Text(l10n.bufferHint),
              ),
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

  /// Settings → Playback → Player engine (app-wide, platform/engine.dart): shown where gerdTV's own libmpv is
  /// installed; the choice applies at the next start.
  SettingsEntry _engineEntry(AppLocalizations l10n) => SettingsEntry(
    id: 'engine',
    title: l10n.playerEngine,
    keywords: l10n.settingsKeywordsEngine,
    build: (_) => StatefulBuilder(
      builder: (context, setState) {
        final dir = session.appDir!;
        final engine = readEngine(dir);
        return ListTile(
          title: Text(l10n.playerEngine),
          subtitle: Text(l10n.playerEngineHint),
          trailing: DropdownButton<PlayerEngine>(
            key: const Key('settings.engine'),
            value: engine,
            items: [
              DropdownMenuItem(
                value: PlayerEngine.standard,
                child: Text(l10n.playerEngineStandard),
              ),
              DropdownMenuItem(
                value: PlayerEngine.gerdtv,
                child: Text(l10n.playerEngineGerdtv),
              ),
            ],
            onChanged: (v) =>
                setState(() => writeEngine(dir, v ?? PlayerEngine.standard)),
          ),
        );
      },
    ),
  );

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
                        : _CategoryContent(category: selected),
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

  /// The search results: matching entries under their category's title, or a line saying nothing matched.
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
      padding: const EdgeInsets.symmetric(vertical: Tokens.space),
      children: [
        for (final cat in matches) ...[
          _header(context, cat.title),
          ..._entries(context, cat.entries),
        ],
      ],
    );
  }
}

Widget _header(BuildContext context, String title) => ListTile(
  title: Text(title, style: Theme.of(context).textTheme.titleMedium),
);

/// A category's entries, with a subcategory heading wherever the section changes.
List<Widget> _entries(BuildContext context, List<SettingsEntry> entries) {
  String? section;
  return [
    for (final e in entries) ...[
      if (e.section != null && e.section != section)
        Padding(
          key: Key('settings.section.${e.section}'),
          padding: const EdgeInsets.fromLTRB(
            Tokens.space * 2,
            Tokens.space * 2,
            Tokens.space * 2,
            Tokens.space / 2,
          ),
          child: Text(
            (section = e.section)!,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      KeyedSubtree(key: Key('settings.entry.${e.id}'), child: e.build(context)),
    ],
  ];
}

/// One category's entries, scrollable (key `settings.content`, which the integration tests scroll).
class _CategoryContent extends StatelessWidget {
  const _CategoryContent({required this.category, this.header = true});
  final SettingsCategory category;
  final bool header; // the phone page has the title in its app bar
  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('settings.content'),
    padding: const EdgeInsets.symmetric(vertical: Tokens.space),
    children: [
      if (header) _header(context, category.title),
      ..._entries(context, category.entries),
    ],
  );
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
