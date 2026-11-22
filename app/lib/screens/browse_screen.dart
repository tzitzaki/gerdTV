// Browse one kind (Live TV, Movies, Series): the provider's groups in provider order, then a group's items
// (paged, 100 at a time, more on scroll). Series open their episodes; everything else plays.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'item_tile.dart';
import 'player_screen.dart';

/// Plays an item, or opens a series' episodes.
void openItem(BuildContext context, Session session, ItemInfo item) {
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

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

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
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final f = _filter.text.toLowerCase();
    // The instant filter narrows what is loaded; groups beyond a few pages are rare and load on scroll.
    final shown = f.isEmpty
        ? _items
        : _items.where((i) => i.name.toLowerCase().contains(f)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.name)),
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
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 600) _more();
                return false;
              },
              child: ListView.builder(
                itemCount: shown.length + (_loading ? 1 : 0),
                itemBuilder: (context, i) => i == shown.length
                    ? const Padding(
                        padding: EdgeInsets.all(Tokens.space * 2),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : ItemTile(
                        item: shown[i],
                        onTap: () =>
                            openItem(context, widget.session, shown[i]),
                      ),
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
