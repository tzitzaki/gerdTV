// Search inside a section (docs/SPEC.md, Search): Live TV, Movies, Series and the Guide each have one field on top.
// While it is empty the section looks as always ([SectionSearch.child]); typing replaces that with the results:
// - Live TV, Movies, Series: matching groups on top (one tap opens them), then the items in the section's list mode
//   with the matched text in bold and each item's group.
// - TV (lists and guide): channels, then programmes by currency: "Live now", "Upcoming" (5 each and "Show all" in the
//   lists, all of them in the guide), and "Show earlier" loads the ended ones on demand.
// - With a group ([SectionSearch.group]): chips "All groups" and the group switch between the section and that group
//   (programmes follow). Inside a group the search starts in it; the guide passes its shown group and starts wide.
// - A line "Also in Movies 3 · Series 2" jumps to another section with the same query ([SectionSearch.onJump]).
// The core does the matching and ranking (gerdtv-core db.rs `search`); answers to older keystrokes are dropped
// (SearchModel). Enter opens the top result. An empty, focused field lists the section's recent searches (those
// whose result was opened). On Android the empty field has a mic: the system's speech recognizer types for you.
//
// Debugging "my search finds nothing": try the query in a sqlite3 shell on the profile db (docs/DATA_MODEL.md);
// no hits at all after an update means the search index is still empty, which the first sync after migration 6 fills.

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/search_model.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'browse_screen.dart';
import 'group_menus.dart';
import 'item_tile.dart';
import 'list_modes.dart';
import 'programme_sheet.dart';
import 'programme_text.dart';
import 'search_text.dart';

enum SearchSection { live, guide, movies, series }

/// The kinds a section's search finds; the series section also finds episodes (after the series).
List<ItemKind> sectionKinds(SearchSection s) => switch (s) {
  SearchSection.live => const [ItemKind.live],
  SearchSection.movies => const [ItemKind.movie],
  SearchSection.series => const [ItemKind.series, ItemKind.episode],
  SearchSection.guide => const [
    ItemKind.live,
  ], // the guide lists channels first too
};

SearchSection sectionOf(ItemKind k) => switch (k) {
  ItemKind.live => SearchSection.live,
  ItemKind.movie => SearchSection.movies,
  ItemKind.series || ItemKind.episode => SearchSection.series,
};

String sectionName(AppLocalizations l10n, SearchSection s) => switch (s) {
  SearchSection.live => l10n.navLive,
  SearchSection.guide => l10n.navGuide,
  SearchSection.movies => l10n.navMovies,
  SearchSection.series => l10n.navSeries,
};

class SectionSearch extends StatefulWidget {
  const SectionSearch({
    super.key,
    required this.session,
    required this.section,
    required this.controller,
    required this.child,
    this.focus,
    this.group,
    this.startInGroup = true,
    this.onJump,
    this.action,
  });
  final Session session;
  final SearchSection section;

  /// Owned by the caller, so a section keeps its query while another one is shown (until cleared).
  final TextEditingController controller;
  final FocusNode? focus;

  /// The group the chips can limit the search to (inside a group, or the guide's shown group).
  final CategoryInfo? group;

  /// Whether the search starts limited to [group] (inside a group) or covers the section (the guide).
  final bool startInGroup;

  /// The "Also in" line: switch to another section with this query. Null: no line (inside a group).
  final void Function(SearchSection section, String query)? onJump;

  /// Beside the field (TV's switch between lists and guide).
  final Widget? action;
  final Widget child;

  @override
  State<SectionSearch> createState() => _SectionSearchState();
}

class _SectionSearchState extends State<SectionSearch> {
  static const _programmeLimit = 100;

  /// Live TV shows this many programmes under the channels, then "Show all".
  static const _programmesInline = 5;

  late final SearchModel _model = SearchModel(
    (seq, q, category, offset) => widget.session.library!.search(
      seq: BigInt.from(seq),
      query: q,
      kinds: sectionKinds(widget.section),
      category: category,
      limit: SearchModel.pageSize,
      offset: offset,
    ),
    category: widget.startInGroup ? widget.group?.id : null,
  );
  late final FocusNode _focus = widget.focus ?? FocusNode();
  String _asked = '';
  List<ProgrammeHit> _live = const [];
  List<ProgrammeHit> _upcoming = const [];

  /// Null until "Show earlier" was tapped for this query.
  List<ProgrammeHit>? _earlier;
  List<String> _recent = const [];

  /// Android with a speech recognizer installed: the mic shows in the empty field.
  bool _voice = false;
  final Map<String, NowNext> _nowNext = {};

  /// The section's group names by (kind, id): the core's search leaves them out (they cost it a sixth of a short
  /// search), each hit shows its group. Loaded once; a group missing here (an episode's series) shows none.
  final Map<(ItemKind, String), String> _groupNames = {};

  bool get _withProgrammes =>
      widget.section == SearchSection.live ||
      widget.section == SearchSection.guide;

  late final ListMode _mode = parseListMode(
    widget.session.library!.setting(
      key: listModeSetting(
        sectionKinds(widget.section).firstOrNull ?? ItemKind.live,
      ),
    ),
    sectionKinds(widget.section).firstOrNull ?? ItemKind.live,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _focus.addListener(_onFocus);
    _model.addListener(_onResults);
    _search(); // a query kept from before (the section was shown earlier)
    for (final kind in sectionKinds(widget.section)) {
      widget.session.library
          ?.categories(kind: kind, sort: ListSort.provider.value) // names only
          .then((groups) {
            if (!mounted) return;
            setState(() {
              for (final g in groups) {
                _groupNames[(kind, g.id)] = g.name;
              }
            });
          });
    }
    widget.session.platform.voiceAvailable.then((v) {
      if (mounted && v) setState(() => _voice = true);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.removeListener(_onFocus);
    if (widget.focus == null) _focus.dispose();
    _model.dispose();
    super.dispose();
  }

  /// The guide showed another group: a search limited to the old one moves along.
  @override
  void didUpdateWidget(SectionSearch old) {
    super.didUpdateWidget(old);
    if (widget.group?.id != old.group?.id && _model.category != null) {
      _setCategory(widget.group?.id);
    }
  }

  /// The chips: the section or the group; the programmes follow.
  void _setCategory(String? category) {
    _model.setCategory(category);
    _findProgrammes(widget.controller.text);
  }

  /// Every change of the text (typing, type-to-search, a recent search, the "Also in" jump) runs the search once.
  void _onText() {
    if (widget.controller.text == _asked) return;
    _search();
    _onFocus(); // the recent searches show only while the field is empty
  }

  void _search() {
    final q = _asked = widget.controller.text;
    _model.set(q);
    if (_withProgrammes) _findProgrammes(q);
  }

  void _onFocus() {
    if (!mounted) return;
    final lib = widget.session.library;
    setState(() {
      _recent = _focus.hasFocus && widget.controller.text.isEmpty && lib != null
          ? lib.recentSearches(section: widget.section.name, limit: 5)
          : const [];
    });
  }

  /// What is on for the live hits (the list mode's now/next lines).
  Future<void> _onResults() async {
    if (!_withProgrammes || _model.hits.isEmpty) return;
    final keys = [for (final h in _model.hits) h.key];
    final rows = await widget.session.library!.nowNext(keys: keys);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < keys.length; i++) {
        _nowNext[keys[i]] = rows[i];
      }
    });
  }

  /// Answers to an older query are dropped (the field moved on), like the item search's sequence numbers. Live and
  /// upcoming are asked at once; the ended ones only from "Show earlier".
  Future<void> _findProgrammes(String q) async {
    final lib = widget.session.library;
    _earlier = null;
    if (lib == null || q.trim().isEmpty) {
      _live = const [];
      _upcoming = const [];
      return; // the build that follows the text change shows the section again
    }
    final category = _model.category;
    final live = await _programmesOf(q, ProgrammeWhen.live);
    final upcoming = await _programmesOf(q, ProgrammeWhen.upcoming);
    if (mounted && q == widget.controller.text && category == _model.category) {
      setState(() {
        _live = live;
        _upcoming = upcoming;
      });
    }
  }

  Future<List<ProgrammeHit>> _programmesOf(String q, ProgrammeWhen when) =>
      widget.session.library!.searchProgrammes(
        query: q,
        limit: _programmeLimit,
        when: when,
        category: _model.category,
      );

  Future<void> _showEarlier() async {
    final q = widget.controller.text;
    final earlier = await _programmesOf(q, ProgrammeWhen.earlier);
    if (mounted && q == widget.controller.text) {
      setState(() => _earlier = earlier);
    }
  }

  /// Opening a result remembers the query for the recent searches.
  void _remember() => widget.session.library?.recordSearch(
    section: widget.section.name,
    query: widget.controller.text,
  );

  void _openItem(ItemInfo it) {
    _remember();
    openItem(
      context,
      widget.session,
      it,
      channels: it.kind == ItemKind.live ? List.of(_model.hits) : null,
    );
  }

  void _openGroup(GroupHit g) {
    _remember();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ItemsScreen(
          session: widget.session,
          kind: g.kind,
          group: CategoryInfo(id: g.id, name: g.name, count: g.count),
        ),
      ),
    );
  }

  void _openProgramme(ProgrammeHit h) {
    _remember();
    showProgrammeSheet(context, widget.session, h.programme, h.item);
  }

  /// Enter: the first item, else the first group, else the first programme's channel.
  void _openTop() {
    final programmes = [..._live, ..._upcoming];
    if (_model.hits.isNotEmpty) {
      _openItem(_model.hits.first);
    } else if (_model.groups.isNotEmpty) {
      _openGroup(_model.groups.first);
    } else if (programmes.isNotEmpty) {
      _remember();
      openItem(context, widget.session, programmes.first.item);
    }
  }

  /// The mic: what the recognizer heard becomes the query.
  Future<void> _listen(String prompt) async {
    final heard = await widget.session.platform.listen(prompt);
    if (heard == null || !mounted) return;
    widget.controller.value = TextEditingValue(
      text: heard,
      selection: TextSelection.collapsed(offset: heard.length),
    );
  }

  /// [h] with its group's name, when the hit came without one.
  ItemInfo _withGroup(ItemInfo h) {
    final name = _groupNames[(h.kind, h.category)];
    if (h.group.isNotEmpty || name == null) return h;
    return ItemInfo(
      key: h.key,
      kind: h.kind,
      name: h.name,
      category: h.category,
      logo: h.logo,
      number: h.number,
      archiveDays: h.archiveDays,
      group: name,
    );
  }

  String _hint(AppLocalizations l10n) =>
      widget.group != null && _model.category != null
      ? l10n.searchHintGroup(widget.group!.name)
      : switch (widget.section) {
          SearchSection.live => l10n.searchHintLive,
          SearchSection.guide => l10n.searchHintGuide,
          SearchSection.movies => l10n.searchHintMovies,
          SearchSection.series => l10n.searchHintSeries,
        };

  /// Totals of one section from the per-kind counts.
  int _countOf(SearchSection s) => _model.counts
      .where((c) => sectionKinds(s).contains(c.kind))
      .fold(0, (n, c) => n + c.count);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final q = widget.controller.text;
    final field = Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.space,
        Tokens.space,
        Tokens.space,
        0,
      ),
      // Enter (hardware keyboard) opens the top result; a key the framework handles never reaches the text input, so
      // this can't fire twice. onSubmitted covers on-screen keyboards.
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter): _openTop},
        child: TextField(
          key: Key('search.${widget.section.name}'),
          controller: widget.controller,
          focusNode: _focus,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: _hint(l10n),
            suffixIcon: q.isEmpty
                ? (_voice
                      ? IconButton(
                          key: const Key('search.voice'),
                          icon: const Icon(Icons.mic_none),
                          tooltip: l10n.searchVoice,
                          onPressed: () => _listen(_hint(l10n)),
                        )
                      : null)
                : IconButton(
                    key: const Key('search.clear'),
                    icon: const Icon(Icons.clear),
                    tooltip: l10n.clear,
                    onPressed: widget.controller.clear,
                  ),
          ),
          onSubmitted: (_) => _openTop(),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: field),
            if (widget.action case final action?)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  Tokens.space,
                  Tokens.space,
                  0,
                ),
                child: action,
              ),
          ],
        ),
        Expanded(
          child: q.isEmpty
              ? (_recent.isEmpty ? widget.child : _recentList(l10n))
              : ListenableBuilder(
                  listenable: _model,
                  builder: (context, _) => _itemResults(l10n),
                ),
        ),
      ],
    );
  }

  Widget _recentList(AppLocalizations l10n) => ListView(
    children: [
      SectionLabel(l10n.searchRecent),
      for (final (i, r) in _recent.indexed)
        ListTile(
          key: Key('search.recent.$i'),
          leading: const Icon(Icons.history),
          title: Text(r),
          onTap: () => widget.controller.value = TextEditingValue(
            text: r,
            selection: TextSelection.collapsed(offset: r.length),
          ),
        ),
    ],
  );

  Widget _itemResults(AppLocalizations l10n) {
    final q = widget.controller.text;
    final text = Theme.of(context).textTheme;
    final nothing =
        _model.hits.isEmpty &&
        _model.groups.isEmpty &&
        _live.isEmpty &&
        _upcoming.isEmpty &&
        (_earlier?.isEmpty ?? true);
    final others = widget.onJump == null
        ? const <(SearchSection, int)>[]
        : [
            for (final s in [
              SearchSection.live,
              SearchSection.movies,
              SearchSection.series,
            ])
              // The guide's channels are TV's: no jump to TV from it.
              if (s != sectionOf(sectionKinds(widget.section).first) &&
                  _countOf(s) > 0)
                (s, _countOf(s)),
          ];
    final all = _countOf(widget.section);
    return ItemsView(
      mode: _mode,
      items: [for (final h in _model.hits) _withGroup(h)],
      nowNext: _nowNext,
      now: DateTime.now(),
      onNearEnd: _model.loadMore,
      highlight: q,
      favourites: widget.session.favourites,
      watched: widget.session.watched,
      menu: (it) => itemMenu(context, widget.session, it),
      onFavourite: (it) {
        widget.session.toggleFavourite(it);
        setState(() {}); // the star changes at once
      },
      onTap: _openItem,
      leading: [
        if (widget.group != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.space),
              child: Wrap(
                spacing: Tokens.space,
                children: [
                  ChoiceChip(
                    key: const Key('search.allGroups'),
                    label: Text(l10n.searchAllGroups(all)),
                    selected: _model.category == null,
                    onSelected: (_) => _setCategory(null),
                  ),
                  ChoiceChip(
                    key: const Key('search.thisGroup'),
                    label: Text(widget.group!.name),
                    selected: _model.category != null,
                    onSelected: (_) => _setCategory(widget.group!.id),
                  ),
                ],
              ),
            ),
          ),
        SliverList.list(
          children: [
            for (final g in _model.groups)
              ListTile(
                key: Key('search.group.${g.id}'),
                leading: const Icon(Icons.folder_outlined),
                title: Text.rich(
                  highlightSpan(g.name, q, null),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text('${g.count}'),
                onTap: () => _openGroup(g),
              ),
          ],
        ),
        if (nothing)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(Tokens.space * 3),
              child: Center(child: Text(l10n.searchNoResults(q))),
            ),
          ),
      ],
      trailing: [
        if (_withProgrammes)
          ...programmeSlivers(
            context,
            l10n,
            _live,
            _upcoming,
            _earlier,
            onTap: _openProgramme,
            inline: widget.section == SearchSection.live
                ? _programmesInline
                : null,
            showAll: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProgrammeResultsScreen(
                  query: q,
                  live: _live,
                  upcoming: _upcoming,
                  loadEarlier: () => _programmesOf(q, ProgrammeWhen.earlier),
                  onTap: _openProgramme,
                ),
              ),
            ),
            onEarlier: _showEarlier,
          ),
        if (others.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(Tokens.space),
              child: Wrap(
                spacing: Tokens.space,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(l10n.searchAlsoIn, style: text.bodyMedium),
                  for (final (s, n) in others)
                    ActionChip(
                      key: Key('search.also.${s.name}'),
                      label: Text('${sectionName(l10n, s)} $n'),
                      onPressed: () => widget.onJump!(s, q),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Programme hits as slivers: "Live now" and "Upcoming" (each its first [inline] rows, all with null), a "Show all"
/// button when that cut something ([showAll]), then the ended ones under "Earlier" once loaded ([earlier] not null),
/// or a "Show earlier" button that loads them ([onEarlier]).
List<Widget> programmeSlivers(
  BuildContext context,
  AppLocalizations l10n,
  List<ProgrammeHit> live,
  List<ProgrammeHit> upcoming,
  List<ProgrammeHit>? earlier, {
  required void Function(ProgrammeHit) onTap,
  int? inline,
  VoidCallback? showAll,
  VoidCallback? onEarlier,
}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  Widget row(ProgrammeHit h) => ItemTile(
    key: Key('search.programme.${h.programme.id}'),
    item: h.item,
    title: h.programme.title,
    subtitle: '${h.item.name} · ${programmeWhen(l10n, locale, h.programme)}',
    onTap: () => onTap(h),
  );
  List<Widget> group(String key, String header, List<ProgrammeHit> hits) => [
    if (hits.isNotEmpty) ...[
      SliverToBoxAdapter(child: SectionLabel(header, key: Key('search.$key'))),
      SliverList.list(
        children: [for (final h in hits.take(inline ?? hits.length)) row(h)],
      ),
    ],
  ];
  final cut =
      inline != null && (live.length > inline || upcoming.length > inline);
  Widget button(String key, String label, VoidCallback onPressed) =>
      SliverToBoxAdapter(
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.space),
            child: TextButton(
              key: Key(key),
              onPressed: onPressed,
              child: Text(label),
            ),
          ),
        ),
      );
  return [
    ...group('programmes.live', l10n.searchLiveNow, live),
    ...group('programmes.upcoming', l10n.searchUpcoming, upcoming),
    if (cut && showAll != null)
      button(
        'search.programmes.all',
        l10n.searchShowAll(live.length + upcoming.length),
        showAll,
      ),
    if (earlier != null)
      ...group('earlier', l10n.searchEarlier, earlier)
    else if (onEarlier != null)
      button('search.showEarlier', l10n.searchShowEarlier, onEarlier),
  ];
}

/// Live TV's "Show all": every live and upcoming programme hit, and the ended ones on demand.
class ProgrammeResultsScreen extends StatefulWidget {
  const ProgrammeResultsScreen({
    super.key,
    required this.query,
    required this.live,
    required this.upcoming,
    required this.loadEarlier,
    required this.onTap,
  });
  final String query;
  final List<ProgrammeHit> live;
  final List<ProgrammeHit> upcoming;
  final Future<List<ProgrammeHit>> Function() loadEarlier;
  final void Function(ProgrammeHit) onTap;

  @override
  State<ProgrammeResultsScreen> createState() => _ProgrammeResultsScreenState();
}

class _ProgrammeResultsScreenState extends State<ProgrammeResultsScreen> {
  List<ProgrammeHit>? _earlier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${l10n.searchProgrammes} · ${widget.query}')),
      body: CustomScrollView(
        slivers: programmeSlivers(
          context,
          l10n,
          widget.live,
          widget.upcoming,
          _earlier,
          onTap: widget.onTap,
          onEarlier: () async {
            final earlier = await widget.loadEarlier();
            if (mounted) setState(() => _earlier = earlier);
          },
        ),
      ),
    );
  }
}

/// Typing a letter or digit anywhere in [child], outside a text field, starts the search of [field] with it (owner
/// decision: fewer steps). `/` and Ctrl/Cmd+F focus the field. D-pad and other keys pass through untouched.
class TypeToSearch extends StatelessWidget {
  const TypeToSearch({
    super.key,
    required this.focus,
    required this.child,
    this.field,
  });
  final FocusNode focus;

  /// Null: only the shortcuts (Settings, whose search filters rather than searches).
  final TextEditingController? field;
  final Widget child;

  static final _typable = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

  /// True while a text field has the focus: its keys are its own.
  static bool _editing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        (ctx.widget is EditableText ||
            ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final command = keys.isControlPressed || keys.isMetaPressed;
    if (command && e.logicalKey == LogicalKeyboardKey.keyF) {
      focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (_editing() || command || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.slash) {
      focus.requestFocus();
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (field == null || ch == null || !_typable.hasMatch(ch)) {
      return KeyEventResult.ignored;
    }
    final text = field!.text + ch;
    field!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    focus.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _key,
    child: child,
  );
}
