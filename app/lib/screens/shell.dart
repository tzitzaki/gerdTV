// The app shell (docs/DESIGN.md): a sidebar on wide windows (desktop, tablet), a bottom bar on phones. Sections:
// Live TV, Guide, Movies, Series, Search, Settings. While a sync runs, a thin bar shows at the top; a failed sync says so
// with a retry, over the cached catalogue.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'browse_screen.dart';
import 'guide_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.session});
  final Session session;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _goSearch() {
    setState(() => _index = 4);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    final destinations = [
      (Icons.live_tv, l10n.navLive),
      (Icons.calendar_view_week, l10n.navGuide),
      (Icons.movie_outlined, l10n.navMovies),
      (Icons.video_library_outlined, l10n.navSeries),
      (Icons.search, l10n.navSearch),
      (Icons.settings_outlined, l10n.navSettings),
    ];
    final page = switch (_index) {
      0 => BrowseScreen(
        key: const ValueKey('live'),
        session: s,
        kind: ItemKind.live,
      ),
      1 => GuideScreen(session: s),
      2 => BrowseScreen(
        key: const ValueKey('movies'),
        session: s,
        kind: ItemKind.movie,
      ),
      3 => BrowseScreen(
        key: const ValueKey('series'),
        session: s,
        kind: ItemKind.series,
      ),
      4 => SearchScreen(session: s, focus: _searchFocus),
      _ => SettingsScreen(session: s),
    };
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
        Expanded(child: page),
      ],
    );
    return CallbackShortcuts(
      bindings: {for (final a in searchShortcuts) a: _goSearch},
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
            return Scaffold(
              body: SafeArea(child: body),
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
