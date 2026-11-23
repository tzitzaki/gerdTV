// The app shell (docs/DESIGN.md): a sidebar on wide windows (desktop, tablet), a bottom bar on phones. Sections:
// Live TV, Guide, Movies, Series, Settings; the first four have their own search on top (section_search.dart), whose
// query the shell keeps while another section is shown. While a sync runs, a thin bar shows at the top; a failed sync
// says so with a retry, over the cached catalogue. On phones a horizontal fling switches to the neighbouring section
// (not on the Guide, whose grid scrolls sideways).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'browse_screen.dart';
import 'guide_screen.dart';
import 'section_search.dart';
import 'settings_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.session});
  final Session session;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  /// Navigation index → section (Settings, index 4, has its own settings search).
  static const _sections = [
    SearchSection.live,
    SearchSection.guide,
    SearchSection.movies,
    SearchSection.series,
  ];
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
    setState(() => _index = _sections.indexOf(to));
  }

  Widget _search(SearchSection s, Widget child) => SectionSearch(
    key: ValueKey(s),
    session: widget.session,
    section: s,
    controller: _queries[s]!,
    focus: _focus[s],
    onJump: _jump,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    final destinations = [
      (Icons.live_tv, l10n.navLive),
      (Icons.calendar_view_week, l10n.navGuide),
      (Icons.movie_outlined, l10n.navMovies),
      (Icons.video_library_outlined, l10n.navSeries),
      (Icons.settings_outlined, l10n.navSettings),
    ];
    final page = switch (_index) {
      0 => _search(
        SearchSection.live,
        BrowseScreen(
          key: const ValueKey('live'),
          session: s,
          kind: ItemKind.live,
        ),
      ),
      1 => _search(SearchSection.guide, GuideScreen(session: s)),
      2 => _search(
        SearchSection.movies,
        BrowseScreen(
          key: const ValueKey('movies'),
          session: s,
          kind: ItemKind.movie,
        ),
      ),
      3 => _search(
        SearchSection.series,
        BrowseScreen(
          key: const ValueKey('series'),
          session: s,
          kind: ItemKind.series,
        ),
      ),
      _ => SettingsScreen(session: s, focus: _settingsFocus),
    };
    final section = _index < _sections.length ? _sections[_index] : null;
    final body = Column(
      children: [
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
            key: ValueKey(_index),
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
                      NavigationRail(
                        selectedIndex: _index,
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
                        onDestinationSelected: (i) =>
                            setState(() => _index = i),
                        destinations: [
                          for (final d in destinations)
                            NavigationRailDestination(
                              icon: Icon(d.$1),
                              label: Text(d.$2),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  ),
                ),
              );
            }
            // Phones: a horizontal fling moves to the neighbouring section (owner decision), except on the Guide,
            // where a horizontal drag scrolls time.
            return Scaffold(
              body: SafeArea(
                child: SectionSwipe(
                  enabled: _index != 1,
                  onPrevious: _index > 0
                      ? () => setState(() => _index--)
                      : null,
                  onNext: _index < destinations.length - 1
                      ? () => setState(() => _index++)
                      : null,
                  child: body,
                ),
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                destinations: [
                  for (final d in destinations)
                    NavigationDestination(icon: Icon(d.$1), label: d.$2),
                ],
              ),
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
