// Browse one kind (Live TV, Movies, Series): the provider's groups in provider order, then a group's items
// (paged, 100 at a time, more on scroll) in the section's list mode, live channels with what's on now and next.
// Series open their episodes; everything else plays. A group's own search field searches the whole group in the
// core (section_search.dart), not just the rows loaded so far.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'item_tile.dart';
import 'list_modes.dart';
import 'logo.dart';
import 'player_screen.dart';
import 'section_search.dart';

/// Plays an item, or opens a series' episodes. [channels]: the live channels around it (Up/Down in the player).
void openItem(
  BuildContext context,
  Session session,
  ItemInfo item, {
  List<ItemInfo>? channels,
}) {
  // Opened without a list (a programme, an episode): no zapping through an older list.
  if (item.kind == ItemKind.live) session.zapList = channels ?? const [];
  if (item.kind == ItemKind.series) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EpisodesScreen(session: session, series: item),
      ),
    );
  } else {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(session: session, item: item),
      ),
    );
  }
}

class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key, required this.session, required this.kind});
  final Session session;
  final ItemKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final lib = session.library!;
        final groups = lib.categories(kind: kind);
        return FutureBuilder<List<CategoryInfo>>(
          key: ValueKey(session.generation),
          future: groups,
          builder: (context, snap) {
            if (snap.hasError) {
              return _Message(l10n.syncFailed('${snap.error}'));
            }
            final list = snap.data;
            if (list == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (list.isEmpty) {
              return _Message(
                session.syncing ? l10n.syncing : l10n.browseEmpty,
              );
            }
            // The favourites of this section come first, as a group of their own (when there are any); movies and
            // series show what was left part-way above them (refreshed whenever playback starts or stops).
            return ListenableBuilder(
              listenable: Listenable.merge([
                session.favouritesChanged,
                session.nowPlaying,
              ]),
              builder: (context, _) => FutureBuilder<List<ItemInfo>>(
                future: lib.favourites(kinds: sectionKinds(sectionOf(kind))),
                builder: (context, favs) {
                  final n = favs.data?.length ?? 0;
                  final all = [
                    if (n > 0)
                      CategoryInfo(id: '', name: l10n.favourites, count: n),
                    ...list,
                  ];
                  final resume = kind == ItemKind.live
                      ? null
                      : ContinueRow(session: session, kind: kind);
                  return ListView.builder(
                    itemCount: all.length + (resume == null ? 0 : 1),
                    itemBuilder: (context, row) {
                      if (resume != null && row == 0) return resume;
                      final i = resume == null ? row : row - 1;
                      return ListTile(
                        key: n > 0 && i == 0
                            ? const Key('browse.favourites')
                            : null,
                        leading: n > 0 && i == 0
                            ? const Icon(Icons.star)
                            : null,
                        title: Text(all[i].name),
                        trailing: Text('${all[i].count}'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ItemsScreen(
                              session: session,
                              kind: kind,
                              group: all[i],
                              favourites: n > 0 && i == 0,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// Continue watching (movies, series): started, unfinished movies or episodes as a row of tiles with how far they
/// got, last watched first; a tile continues where it was left. Shows nothing until something was started.
class ContinueRow extends StatelessWidget {
  const ContinueRow({super.key, required this.session, required this.kind});
  final Session session;
  final ItemKind kind;

  static const _limit = 20;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<ResumeItem>>(
      future: session.library!.continueWatching(
        kinds: sectionKinds(sectionOf(kind)),
        limit: _limit,
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tokens.space * 2,
                Tokens.space,
                Tokens.space * 2,
                0,
              ),
              child: Text(l10n.continueWatching, style: text.titleSmall),
            ),
            SizedBox(
              height: 200,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(Tokens.space),
                children: [
                  for (final r in rows)
                    SizedBox(
                      width: 130,
                      child: Card(
                        key: Key('continue.${r.item.key}'),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => openItem(context, session, r.item),
                          child: Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, c) => Logo(
                                    url: r.item.logo,
                                    size: c.biggest.shortestSide,
                                    icon: kindIcon(r.item.kind),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(Tokens.space / 2),
                                child: Text(
                                  r.item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: text.bodySmall,
                                ),
                              ),
                              LinearProgressIndicator(
                                value: r.duration > 0
                                    ? r.position / r.duration
                                    : null,
                                minHeight: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class ItemsScreen extends StatefulWidget {
  const ItemsScreen({
    super.key,
    required this.session,
    required this.kind,
    required this.group,
    this.favourites = false,
  });
  final Session session;
  final ItemKind kind;
  final CategoryInfo group;

  /// The section's Favourites group (its items come from the favourites, all at once).
  final bool favourites;

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  static const page = 100;
  final List<ItemInfo> _items = [];
  bool _loading = false;
  bool _done = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// What is on for the loaded live items; refreshed every minute (progress, the next programme) and after each
  /// guide import.
  final Map<String, NowNext> _nowNext = {};
  Timer? _tick;
  int _guideSeen = 0;

  late ListMode _mode = parseListMode(
    widget.session.library!.setting(key: listModeSetting(widget.kind)),
    widget.kind,
  );

  @override
  void initState() {
    super.initState();
    _guideSeen = widget.session.guideGeneration;
    widget.session.addListener(_onSession);
    _tick = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshNowNext(),
    );
    _more();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _tick?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSession() {
    if (widget.session.guideGeneration != _guideSeen) {
      _guideSeen = widget.session.guideGeneration;
      _refreshNowNext();
    }
  }

  Future<void> _nowNextFor(List<ItemInfo> items) async {
    if (widget.kind != ItemKind.live || items.isEmpty) return;
    final keys = [for (final i in items) i.key];
    final rows = await widget.session.library!.nowNext(keys: keys);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < keys.length; i++) {
        _nowNext[keys[i]] = rows[i];
      }
    });
  }

  Future<void> _refreshNowNext() => _nowNextFor(List.of(_items));

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final lib = widget.session.library!;
    final next = widget.favourites
        ? await lib.favourites(kinds: sectionKinds(sectionOf(widget.kind)))
        : await lib.items(
            kind: widget.kind,
            category: widget.group.id,
            limit: page,
            offset: _items.length,
          );
    if (!mounted) return;
    setState(() {
      _items.addAll(next);
      _done = widget.favourites || next.length < page;
      _loading = false;
    });
    await _nowNextFor(next);
  }

  /// The list bar's toggle: the next mode, remembered for this section (the same setting as Settings → Lists).
  void _nextMode() {
    final m = ListMode.values[(_mode.index + 1) % ListMode.values.length];
    widget.session.library!.setSetting(
      key: listModeSetting(widget.kind),
      value: m.name,
    );
    setState(() => _mode = m);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final next = ListMode.values[(_mode.index + 1) % ListMode.values.length];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: [
          IconButton(
            key: const Key('list.mode'),
            tooltip: listModeLabel(l10n, next),
            icon: Icon(listModeIcon(next)),
            onPressed: _nextMode,
          ),
        ],
      ),
      body: TypeToSearch(
        focus: _searchFocus,
        field: _search,
        child: SectionSearch(
          session: widget.session,
          section: sectionOf(widget.kind),
          controller: _search,
          focus: _searchFocus,
          // The Favourites group spans several groups: its search covers the section.
          group: widget.favourites ? null : widget.group,
          child: ValueListenableBuilder<int>(
            valueListenable: widget.session.favouritesChanged,
            builder: (context, _, _) => ItemsView(
              mode: _mode,
              // In Favourites, an unstarred item leaves the list at once.
              items: widget.favourites
                  ? [
                      for (final i in _items)
                        if (widget.session.favourites.contains(i.key)) i,
                    ]
                  : _items,
              nowNext: _nowNext,
              now: DateTime.now(),
              loading: _loading,
              onNearEnd: _more,
              favourites: widget.session.favourites,
              onFavourite: widget.session.toggleFavourite,
              onTap: (it) => openItem(
                context,
                widget.session,
                it,
                channels: widget.kind == ItemKind.live ? List.of(_items) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EpisodesScreen extends StatelessWidget {
  const EpisodesScreen({
    super.key,
    required this.session,
    required this.series,
  });
  final Session session;
  final ItemInfo series;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(series.name)),
      body: FutureBuilder<List<ItemInfo>>(
        future: session.library!.episodes(seriesKey: series.key),
        builder: (context, snap) {
          if (snap.hasError) return _Message(l10n.syncFailed('${snap.error}'));
          final eps = snap.data;
          if (eps == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (eps.isEmpty) return _Message(l10n.episodesEmpty);
          return ListView.builder(
            itemCount: eps.length,
            itemBuilder: (context, i) => ItemTile(
              item: eps[i],
              onTap: () => openItem(context, session, eps[i]),
            ),
          );
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Tokens.space * 3),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
