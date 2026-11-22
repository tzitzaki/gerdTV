// The global search: one field, results narrow with every keystroke, type chips with counts, Enter plays the top
// result. The Programmes chip lists guide programmes (running and upcoming first); tapping one opens its sheet.
// Hidden/PIN groups join in a later phase.

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/search_model.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'browse_screen.dart';
import 'item_tile.dart';
import 'programme_sheet.dart';
import 'programme_text.dart';

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

  /// Guide programmes for the current query, shown under the Programmes chip: running and upcoming (soonest first),
  /// then under "Earlier" the ended ones (most recent first); each group at most [_programmeLimit].
  List<ProgrammeHit> _programmes = const [];
  List<ProgrammeHit> _earlier = const [];
  bool _showProgrammes = false;
  static const _programmeLimit = 100;

  void _changed(String q) {
    _model.set(q);
    _findProgrammes(q);
  }

  /// Answers to an older query are dropped (the field moved on), like the item search's sequence numbers.
  Future<void> _findProgrammes(String q) async {
    final lib = widget.session.library;
    if (lib == null || q.trim().isEmpty) {
      setState(() {
        _programmes = const [];
        _earlier = const [];
      });
      return;
    }
    final hits = await lib.searchProgrammes(
      query: q,
      limit: _programmeLimit,
      earlier: false,
    );
    final earlier = await lib.searchProgrammes(
      query: q,
      limit: _programmeLimit,
      earlier: true,
    );
    if (mounted && q == _field.text) {
      setState(() {
        _programmes = hits;
        _earlier = earlier;
      });
    }
  }

  void _setKind(ItemKind? kind) {
    setState(() => _showProgrammes = false);
    _model.setKind(kind);
  }

  @override
  void dispose() {
    _model.dispose();
    _field.dispose();
    super.dispose();
  }

  void _playTop() {
    if (_showProgrammes) {
      if (_programmes.isNotEmpty) {
        openItem(context, widget.session, _programmes.first.item);
      }
    } else if (_model.hits.isNotEmpty) {
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
                              _changed('');
                            },
                          ),
                  ),
                  onChanged: _changed,
                  onSubmitted: (_) => _playTop(),
                ),
              ),
            ),
            if (_model.counts.isNotEmpty ||
                _programmes.isNotEmpty ||
                _earlier.isNotEmpty)
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
                        selected: !_showProgrammes && _model.kind == null,
                        onSelected: (_) => _setKind(null),
                      ),
                    ),
                    for (final c in _model.counts)
                      Padding(
                        padding: const EdgeInsets.only(right: Tokens.space),
                        child: ChoiceChip(
                          key: Key('search.chip.${c.kind.name}'),
                          label: Text('${_kindName(l10n, c.kind)} ${c.count}'),
                          selected: !_showProgrammes && _model.kind == c.kind,
                          onSelected: (_) => _setKind(c.kind),
                        ),
                      ),
                    if (_programmes.isNotEmpty || _earlier.isNotEmpty)
                      ChoiceChip(
                        key: const Key('search.chip.programmes'),
                        label: Text(
                          '${l10n.chipProgrammes} ${_programmes.length + _earlier.length}'
                          '${_programmes.length == _programmeLimit || _earlier.length == _programmeLimit ? '+' : ''}',
                        ),
                        selected: _showProgrammes,
                        onSelected: (_) =>
                            setState(() => _showProgrammes = true),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _model.query.trim().isEmpty
                  ? Center(child: Text(l10n.searchEmpty))
                  : _showProgrammes
                  ? _programmeList(l10n)
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

  /// Programme hits: title, channel and when; a tap opens the programme's sheet. The ended ones follow under
  /// "Earlier".
  Widget _programmeList(AppLocalizations l10n) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final header = _earlier.isEmpty ? 0 : 1;
    return ListView.builder(
      itemCount: _programmes.length + header + _earlier.length,
      itemBuilder: (context, i) {
        if (header == 1 && i == _programmes.length) {
          return ListTile(
            key: const Key('search.earlier'),
            title: Text(
              l10n.searchEarlier,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }
        final h = i < _programmes.length
            ? _programmes[i]
            : _earlier[i - _programmes.length - header];
        return ItemTile(
          key: Key('search.programme.${h.programme.id}'),
          item: h.item,
          title: h.programme.title,
          subtitle:
              '${h.item.name} · ${programmeWhen(l10n, locale, h.programme)}',
          onTap: () =>
              showProgrammeSheet(context, widget.session, h.programme, h.item),
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
