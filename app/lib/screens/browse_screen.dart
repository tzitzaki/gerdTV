// Browse one kind (Live TV, Movies, Series): the provider's groups in provider order, then a group's items
// (paged, 100 at a time, more on scroll) in the section's list mode, live channels with what's on now and next.
// Series open their episodes; everything else plays.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'item_tile.dart';
import 'list_modes.dart';
import 'player_screen.dart';

/// Plays an item, or opens a series' episodes. [channels]: the live channels around it (Up/Down in the player).
void openItem(
  BuildContext context,
  Session session,
  ItemInfo item, {
  List<ItemInfo>? channels,
}) {
  // Opened without its group (search): no zapping through an older list.
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
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(list[i].name),
                trailing: Text('${list[i].count}'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ItemsScreen(
                      session: session,
                      kind: kind,
                      group: list[i],
                    ),
                  ),
                ),
              ),
            );
          },
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
  });
  final Session session;
  final ItemKind kind;
  final CategoryInfo group;

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  static const page = 100;
  final List<ItemInfo> _items = [];
  bool _loading = false;
  bool _done = false;
  final _filter = TextEditingController();

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
    _filter.dispose();
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
    final next = await widget.session.library!.items(
      kind: widget.kind,
      category: widget.group.id,
      limit: page,
      offset: _items.length,
    );
    if (!mounted) return;
    setState(() {
      _items.addAll(next);
      _done = next.length < page;
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
    final f = _filter.text.toLowerCase();
    // The instant filter narrows what is loaded; groups beyond a few pages are rare and load on scroll.
    final shown = f.isEmpty
        ? _items
        : _items.where((i) => i.name.toLowerCase().contains(f)).toList();
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Tokens.space),
            child: TextField(
              controller: _filter,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.filter_list),
                hintText: l10n.filterHint,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: ItemsView(
              mode: _mode,
              items: shown,
              nowNext: _nowNext,
              now: DateTime.now(),
              loading: _loading,
              onNearEnd: _more,
              onTap: (it) => openItem(
                context,
                widget.session,
                it,
                channels: widget.kind == ItemKind.live ? List.of(shown) : null,
              ),
            ),
          ),
        ],
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
