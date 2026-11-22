// The global search: one field, results narrow with every keystroke, type chips with counts, Enter plays the top
// result. Hidden/PIN groups and EPG programmes join in later phases.

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/search_model.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'browse_screen.dart';
import 'item_tile.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.session, this.focus});
  final Session session;
  final FocusNode? focus;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final SearchModel _model = SearchModel(
    (seq, q, kind, offset) => widget.session.library!.search(
      seq: BigInt.from(seq),
      query: q,
      kind: kind,
      limit: SearchModel.pageSize,
      offset: offset,
    ),
  );
  final _field = TextEditingController();

  @override
  void dispose() {
    _model.dispose();
    _field.dispose();
    super.dispose();
  }

  void _playTop() {
    if (_model.hits.isNotEmpty) {
      openItem(context, widget.session, _model.hits.first);
    }
  }

  String _kindName(AppLocalizations l10n, ItemKind k) => switch (k) {
    ItemKind.live => l10n.navLive,
    ItemKind.movie => l10n.navMovies,
    ItemKind.series => l10n.navSeries,
    ItemKind.episode => l10n.kindEpisodes,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) {
        final total = _model.counts.fold<int>(0, (n, c) => n + c.count);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Tokens.space * 2),
              // Enter (hardware keyboard) plays the top result; a key the framework handles never reaches the text
              // input, so this can't fire twice. onSubmitted covers on-screen keyboards.
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _playTop,
                },
                child: TextField(
                  key: const Key('search.field'),
                  controller: _field,
                  focusNode: widget.focus,
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.searchHint,
                    suffixIcon: _field.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: l10n.clear,
                            onPressed: () {
                              _field.clear();
                              _model.set('');
                            },
                          ),
                  ),
                  onChanged: _model.set,
                  onSubmitted: (_) => _playTop(),
                ),
              ),
            ),
            if (_model.counts.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tokens.space * 2,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: Tokens.space),
                      child: ChoiceChip(
                        label: Text('${l10n.chipAll} $total'),
                        selected: _model.kind == null,
                        onSelected: (_) => _model.setKind(null),
                      ),
                    ),
                    for (final c in _model.counts)
                      Padding(
                        padding: const EdgeInsets.only(right: Tokens.space),
                        child: ChoiceChip(
                          key: Key('search.chip.${c.kind.name}'),
                          label: Text('${_kindName(l10n, c.kind)} ${c.count}'),
                          selected: _model.kind == c.kind,
                          onSelected: (_) => _model.setKind(c.kind),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _model.query.trim().isEmpty
                  ? Center(child: Text(l10n.searchEmpty))
                  : _model.hits.isEmpty
                  ? Center(child: Text(l10n.searchNoResults(_model.query)))
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.extentAfter < 600) _model.loadMore();
                        return false;
                      },
                      child: ListView.builder(
                        itemCount: _model.hits.length,
                        itemBuilder: (context, i) {
                          final h = _model.hits[i];
                          return ItemTile(
                            item: h,
                            subtitle: _kindName(l10n, h.kind),
                            onTap: () => openItem(context, widget.session, h),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// `/` or Ctrl/Cmd+F jumps to search from anywhere in the shell.
final searchShortcuts = <ShortcutActivator>[
  const SingleActivator(LogicalKeyboardKey.slash),
  const SingleActivator(LogicalKeyboardKey.keyF, control: true),
  const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
];
