// The app shell (docs/DESIGN.md): a sidebar on wide windows (desktop, tablet), a bottom bar on phones. Sections:
// TV (the channel lists or the guide grid, switched beside its search field and remembered), Movies, Series (all three
// only with a provider: setup can be skipped), Premiumize while an account is linked, Settings; Settings alone shows
// without a navigation bar. TV, Movies and Series have their own search on top (section_search.dart), whose
// query the shell keeps while another section is shown. While a sync runs, a thin bar shows at the top; a failed sync
// says so with a retry, over the cached catalogue. On phones a horizontal fling switches to the neighbouring section
// (not on the guide, whose grid scrolls sideways).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'browse_screen.dart';
import 'guide_screen.dart';
import 'premiumize_screen.dart';
import 'section_search.dart';
import 'recordings_screen.dart';
import 'settings_screen.dart';

/// A section of the navigation.
enum ShellPage { tv, movies, series, premiumize, settings }

/// Profile setting: TV shows the guide grid ("guide") or the channel lists (default).
const tvViewSetting = 'tv_view';

/// The sections shown: TV, Movies and Series only with a provider, Premiumize only while an account is linked.
List<ShellPage> shellPages({
  required bool provider,
  required bool premiumize,
}) => [
  for (final p in ShellPage.values)
    if (switch (p) {
      ShellPage.tv || ShellPage.movies || ShellPage.series => provider,
      ShellPage.premiumize => premiumize,
      ShellPage.settings => true,
    })
      p,
];

class Shell extends StatefulWidget {
  const Shell({super.key, required this.session});
  final Session session;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// By name, not by index: linking or unlinking Premiumize (in Settings) moves the indexes.
  ShellPage _page = ShellPage.tv;
  late bool _guide =
      widget.session.library?.setting(key: tvViewSetting) == 'guide';

  /// The search of the section shown (Settings has its own, Premiumize none).
  SearchSection? get _section => switch (_page) {
    ShellPage.tv => _guide ? SearchSection.guide : SearchSection.live,
    ShellPage.movies => SearchSection.movies,
    ShellPage.series => SearchSection.series,
    ShellPage.premiumize || ShellPage.settings => null,
  };
  final _queries = {
    for (final s in SearchSection.values) s: TextEditingController(),
  };
  final _focus = {for (final s in SearchSection.values) s: FocusNode()};
  final _settingsFocus = FocusNode();

  @override
  void dispose() {
    for (final c in _queries.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _settingsFocus.dispose();
    super.dispose();
  }

  /// The "Also in" line: the other section with the same query.
  void _jump(SearchSection to, String query) {
    _queries[to]!.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _guide = to == SearchSection.guide;
      _page = switch (to) {
        SearchSection.live || SearchSection.guide => ShellPage.tv,
        SearchSection.movies => ShellPage.movies,
        SearchSection.series => ShellPage.series,
      };
    });
  }

  void _showGuide(bool guide) {
    widget.session.library?.setSetting(
      key: tvViewSetting,
      value: guide ? 'guide' : 'list',
    );
    setState(() => _guide = guide);
  }

  Widget _search(SearchSection s, Widget child) => SectionSearch(
    key: ValueKey(s),
    session: widget.session,
    section: s,
    controller: _queries[s]!,
    focus: _focus[s],
    onJump: _jump,
    action: _page == ShellPage.tv ? _tvView() : null,
    child: child,
  );

  /// TV: the channel lists or the guide.
  Widget _tvView() {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: false,
          tooltip: l10n.tvList,
          icon: Icon(
            Icons.view_list,
            key: const Key('tv.list'),
            semanticLabel: l10n.tvList,
          ),
        ),
        ButtonSegment(
          value: true,
          tooltip: l10n.navGuide,
          icon: Icon(
            Icons.calendar_view_week,
            key: const Key('tv.guide'),
            semanticLabel: l10n.navGuide,
          ),
        ),
      ],
      selected: {_guide},
      onSelectionChanged: (v) => _showGuide(v.single),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    final pages = shellPages(
      provider: s.hasProvider,
      premiumize: s.premiumizeToken != null,
    );
    // Unlinked while shown (another profile), or no provider: the first section there is.
    if (!pages.contains(_page)) _page = pages.first;
    // Settings alone (no provider, nothing linked): no navigation, which needs two destinations.
    final nav = pages.length > 1;
    final index = pages.indexOf(_page);
    void go(int i) => setState(() => _page = pages[i]);
    final destinations = [
      for (final p in pages)
        switch (p) {
          ShellPage.tv => (Icons.live_tv, l10n.navLive),
          ShellPage.movies => (Icons.movie_outlined, l10n.navMovies),
          ShellPage.series => (Icons.video_library_outlined, l10n.navSeries),
          ShellPage.premiumize => (Icons.cloud_outlined, l10n.premiumize),
          ShellPage.settings => (Icons.settings_outlined, l10n.navSettings),
        },
    ];
    Widget browse(SearchSection section, ItemKind kind) => _search(
      section,
      BrowseScreen(key: ValueKey(section), session: s, kind: kind),
    );
    final page = switch (_page) {
      ShellPage.tv =>
        _guide
            ? _search(SearchSection.guide, GuideScreen(session: s))
            : browse(SearchSection.live, ItemKind.live),
      ShellPage.movies => browse(SearchSection.movies, ItemKind.movie),
      ShellPage.series => browse(SearchSection.series, ItemKind.series),
      ShellPage.premiumize => PremiumizeScreen(session: s),
      ShellPage.settings => SettingsScreen(session: s, focus: _settingsFocus),
    };
    final section = _section;
    final body = Column(
      children: [
        RecordingConflict(session: s),
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            if (s.syncing) return const LinearProgressIndicator(minHeight: 2);
            if (s.syncError != null) {
              return MaterialBanner(
                content: Text(l10n.syncFailed(s.syncError!)),
                actions: [
                  TextButton(onPressed: s.sync, child: Text(l10n.retry)),
                ],
              );
            }
            return const SizedBox(height: 2);
          },
        ),
        // A new section fades in (only the new one is built: the old one is gone at once, so finders and focus never
        // see two sections).
        Expanded(
          child: TweenAnimationBuilder<double>(
            key: ValueKey((_page, _guide)),
            tween: Tween(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Tokens.motion,
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: page,
          ),
        ),
      ],
    );
    // Typing in a section searches it; `/` and Ctrl/Cmd+F focus its field (in Settings: the settings search).
    return TypeToSearch(
      focus: section == null ? _settingsFocus : _focus[section]!,
      field: section == null ? null : _queries[section],
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= Tokens.wideLayout) {
              return Scaffold(
                body: SafeArea(
                  child: Row(
                    children: [
                      if (nav) ...[
                        NavigationRail(
                          selectedIndex: index,
                          labelType: NavigationRailLabelType.all,
                          leading: ListenableBuilder(
                            listenable: s,
                            builder: (context, _) => Padding(
                              padding: const EdgeInsets.only(
                                bottom: Tokens.space,
                              ),
                              child: AppLogoMark(logo: s.logo, size: 40),
                            ),
                          ),
                          onDestinationSelected: go,
                          destinations: [
                            for (final d in destinations)
                              NavigationRailDestination(
                                icon: Icon(d.$1),
                                label: Text(d.$2),
                              ),
                          ],
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(child: body),
                    ],
                  ),
                ),
              );
            }
            // Phones: a horizontal fling moves to the neighbouring section (owner decision), except on the guide,
            // where a horizontal drag scrolls time.
            return Scaffold(
              body: SafeArea(
                child: SectionSwipe(
                  enabled: section != SearchSection.guide,
                  onPrevious: index > 0 ? () => go(index - 1) : null,
                  onNext: index < destinations.length - 1
                      ? () => go(index + 1)
                      : null,
                  child: body,
                ),
              ),
              bottomNavigationBar: nav
                  ? NavigationBar(
                      selectedIndex: index,
                      onDestinationSelected: go,
                      destinations: [
                        for (final d in destinations)
                          NavigationDestination(icon: Icon(d.$1), label: d.$2),
                      ],
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }
}

/// A horizontal fling over [child] calls [onNext] (fling left) or [onPrevious] (fling right). Slow drags do nothing,
/// and horizontal lists inside (continue watching) keep their own drags: the gesture arena gives them to the
/// innermost scrollable first. Debugging: a swipe that does nothing usually lost the arena to such a list.
class SectionSwipe extends StatelessWidget {
  const SectionSwipe({
    super.key,
    required this.child,
    this.enabled = true,
    this.onPrevious,
    this.onNext,
  });
  final Widget child;
  final bool enabled;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// How fast a fling must be (logical px per second) to count.
  static const minVelocity = 600.0;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v <= -minVelocity) onNext?.call();
        if (v >= minVelocity) onPrevious?.call();
      },
      child: child,
    );
  }
}
