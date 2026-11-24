// Browse one kind (Live TV, Movies, Series): the provider's groups (in the section's group order), then a group's
// items (paged, 100 at a time, more on scroll, in the section's item order) in the section's list mode, live channels
// with what's on now and next. Series open their episodes under their page's header, movies their page
// (details_screen.dart); everything else plays. Loading shows skeleton rows. A group's own search field searches the whole group in the
// core (section_search.dart), not just the rows loaded so far.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'details_screen.dart';
import 'item_tile.dart';
import 'list_modes.dart';
import 'logo.dart';
import 'player_screen.dart';
import 'section_search.dart';

/// Plays an item, or opens a series' episodes or a movie's page ([page] false: a movie plays at once, as from
/// Continue watching). [channels]: the live channels around it (Up/Down in the player).
void openItem(
  BuildContext context,
  Session session,
  ItemInfo item, {
  List<ItemInfo>? channels,
  bool page = true,
}) {
  Future<void> play() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(session: session, item: item),
    ),
  );
  // Opened without a list (a programme, an episode): no zapping through an older list.
  if (item.kind == ItemKind.live) session.zapList = channels ?? const [];
  if (item.kind == ItemKind.series) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EpisodesScreen(session: session, series: item),
      ),
    );
  } else if (item.kind == ItemKind.movie && page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MovieScreen(library: session.library!, movie: item, onPlay: play),
      ),
    );
  } else {
    play();
  }
}

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.session, required this.kind});
  final Session session;
  final ItemKind kind;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  Session get session => widget.session;
  ItemKind get kind => widget.kind;

  /// The groups' order (provider order or by name), remembered per section.
  late ListSort _sort = parseSort(
    session.library!.setting(key: sortSetting(kind, groups: true)),
  );

  void _setSort(ListSort s) {
    session.library!.setSetting(
      key: sortSetting(kind, groups: true),
      value: s.value,
    );
    setState(() => _sort = s);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final lib = session.library!;
        final groups = lib.categories(kind: kind, sort: _sort.value);
        return FutureBuilder<List<CategoryInfo>>(
          key: ValueKey((session.generation, _sort)),
          future: groups,
          builder: (context, snap) {
            if (snap.hasError) {
              return _Message(l10n.syncFailed('${snap.error}'));
            }
            final list = snap.data;
            if (list == null) {
              return ListView(
                children: [for (var i = 0; i < 8; i++) const SkeletonRow()],
              );
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
                future: lib.favourites(
                  kinds: sectionKinds(sectionOf(kind)),
                  sort:
                      lib.setting(key: sortSetting(kind, groups: false)) ??
                      ListSort.provider.value,
                ),
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
                  // Row 0: the groups' sort button (right-aligned), then continue watching, then the groups.
                  final header = Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SortButton(
                      value: _sort,
                      options: sortOptions(kind, groups: true, xtream: false),
                      onSelected: _setSort,
                    ),
                  );
                  final skip = resume == null ? 1 : 2;
                  return ListView.builder(
                    itemCount: all.length + skip,
                    itemBuilder: (context, row) {
                      if (row == 0) return header;
                      if (resume != null && row == 1) return resume;
                      final i = row - skip;
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
                          onTap: () =>
                              openItem(context, session, r.item, page: false),
                          child: Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, c) => Logo(
                                    url: r.item.logo,
                                    size: c.maxWidth,
                                    icon: kindIcon(r.item.kind),
                                    fill: true,
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

  /// The items' order, remembered per section (the Favourites group and zapping follow it).
  late ListSort _sort = parseSort(
    widget.session.library!.setting(
      key: sortSetting(widget.kind, groups: false),
    ),
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
    final sort = _sort;
    final next = widget.favourites
        ? await lib.favourites(
            kinds: sectionKinds(sectionOf(widget.kind)),
            sort: sort.value,
          )
        : await lib.items(
            kind: widget.kind,
            category: widget.group.id,
            sort: sort.value,
            limit: page,
            offset: _items.length,
          );
    // The order changed while this page loaded: _setSort started over, this page belongs to the old order.
    if (!mounted || sort != _sort) return;
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

  /// The sort button: remembered for this section, and the list starts over in the new order.
  void _setSort(ListSort s) {
    widget.session.library!.setSetting(
      key: sortSetting(widget.kind, groups: false),
      value: s.value,
    );
    setState(() {
      _sort = s;
      _items.clear();
      _done = false;
      _loading = false;
    });
    _more();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final next = ListMode.values[(_mode.index + 1) % ListMode.values.length];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: [
          SortButton(
            value: _sort,
            options: sortOptions(
              widget.kind,
              groups: false,
              xtream: widget.session.profile?.source == SourceKind.xtream,
            ),
            onSelected: _setSort,
          ),
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

class EpisodesScreen extends StatefulWidget {
  const EpisodesScreen({
    super.key,
    required this.session,
    required this.series,
  });
  final Session session;
  final ItemInfo series;

  @override
  State<EpisodesScreen> createState() => _EpisodesScreenState();
}

/// The series' page: its backdrop (with the muted trailer) and details (details_screen.dart), then the episodes.
class _EpisodesScreenState extends State<EpisodesScreen> {
  Session get session => widget.session;
  ItemInfo get series => widget.series;
  late final Future<ItemDetails?> _details = session.library!
      .details(key: series.key)
      .then<ItemDetails?>((d) => d)
      .catchError((Object _) => null);
  late final Future<List<ItemInfo>> _episodes = session.library!.episodes(
    seriesKey: series.key,
  );
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The preview runs only while this page is on top (the player covers it after an episode's tap); ModalRoute.of
    // rebuilds this when that changes.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    return Scaffold(
      body: FutureBuilder<ItemDetails?>(
        future: _details,
        builder: (context, details) => CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 280,
              title: Text(series.name),
              flexibleSpace: FlexibleSpaceBar(
                background: DetailsBackdrop(
                  item: series,
                  details: details.data,
                  active: onTop,
                  fallback: _Backdrop(item: series),
                ),
              ),
            ),
            if (details.data != null)
              SliverToBoxAdapter(
                child: DetailsInfo(item: series, details: details.data),
              ),
            FutureBuilder<List<ItemInfo>>(
              future: _episodes,
              builder: (context, snap) {
                if (snap.hasError) {
                  return SliverFillRemaining(
                    child: _Message(l10n.syncFailed('${snap.error}')),
                  );
                }
                final eps = snap.data;
                if (eps == null) {
                  return SliverList.builder(
                    itemCount: 6,
                    itemBuilder: (_, _) => const SkeletonRow(),
                  );
                }
                if (eps.isEmpty) {
                  return SliverFillRemaining(
                    child: _Message(l10n.episodesEmpty),
                  );
                }
                return SliverList.builder(
                  itemCount: eps.length,
                  itemBuilder: (context, i) => ItemTile(
                    item: eps[i],
                    onTap: () => openItem(context, session, eps[i]),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A series' header (the cinematic look): its poster blurred and darkened across the whole bar, fading into the
/// page, with the poster itself in front (flown in from its tile: the Hero tag matches ItemCard's).
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.item});
  final ItemInfo item;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Logo(
            url: item.logo,
            size: 160, // decoded small: it is blurred anyway
            icon: kindIcon(item.kind),
            fill: true,
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [surface.withValues(alpha: 0.35), surface],
            ),
          ),
        ),
        Positioned(
          left: Tokens.space * 2,
          bottom: Tokens.space * 2,
          width: 100,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Tokens.radius / 2),
            child: Hero(
              tag: 'poster:${item.key}',
              child: Logo(
                url: item.logo,
                size: 100,
                icon: kindIcon(item.kind),
                fill: true,
              ),
            ),
          ),
        ),
      ],
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
