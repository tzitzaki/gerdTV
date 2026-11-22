// The TV guide grid (docs/SPEC.md "TV guide"): channels of one group down the left (fixed), a local-time ruler on top
// (fixed), programmes as cells in between; the body scrolls both ways and drags the column and the ruler along. A
// line marks now. The header shows the focused programme; a cell opens the programme sheet (Watch plays the
// channel). Jumps: Now, 20:15, and a day from 2 back to the kept days ahead. Keyboard and remote move between cells.
// Rows load in pages of 50 channels as they come into view; a page holds the whole day for its channels.
// Debugging: an empty grid means no guide match for the group (Settings → Guide lists the unmatched channels).

import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'browse_screen.dart';
import 'guide_math.dart';
import 'list_modes.dart';
import 'logo.dart';
import 'programme_text.dart';

class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, required this.session});
  final Session session;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  static const _page = 50;

  /// Channels of a group shown at most (a guide of more rows than this is not browsable anyway).
  static const _maxChannels = 1000;

  Library get _lib => widget.session.library!;

  List<CategoryInfo> _groups = const [];
  CategoryInfo? _group;
  List<ItemInfo> _channels = const [];
  late DateTime _day = _today();
  final Map<int, List<GuideRow>> _pages = {};
  final Set<int> _loading = {};
  final _focused = ValueNotifier<(ProgrammeInfo, ItemInfo)?>(null);

  // Body ↔ ruler (horizontal) and body ↔ channel column (vertical) are kept in step by hand.
  final _h = ScrollController(), _ruler = ScrollController();
  final _v = ScrollController(), _column = ScrollController();
  bool _syncing = false;
  Timer? _tick;
  int _guideSeen = 0;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  int get _from => _day.millisecondsSinceEpoch ~/ 1000;
  int get _to =>
      DateTime(_day.year, _day.month, _day.day + 1).millisecondsSinceEpoch ~/
      1000;

  double _pxPerMin(BuildContext c) =>
      MediaQuery.sizeOf(c).width < Tokens.wideLayout ? 3 : 4;

  @override
  void initState() {
    super.initState();
    _link(_h, _ruler);
    _link(_ruler, _h);
    _link(_v, _column);
    _link(_column, _v);
    _guideSeen = widget.session.guideGeneration;
    widget.session.addListener(_onSession);
    // The now line moves and running programmes change: redraw every minute.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
    _loadGroups();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _tick?.cancel();
    for (final c in [_h, _ruler, _v, _column]) {
      c.dispose();
    }
    _focused.dispose();
    super.dispose();
  }

  void _link(ScrollController from, ScrollController to) {
    from.addListener(() {
      if (_syncing || !to.hasClients || !from.hasClients) return;
      _syncing = true;
      to.jumpTo(from.offset.clamp(0, to.position.maxScrollExtent));
      _syncing = false;
    });
  }

  void _onSession() {
    if (widget.session.guideGeneration != _guideSeen) {
      _guideSeen = widget.session.guideGeneration;
      setState(_pages.clear);
    }
  }

  Future<void> _loadGroups() async {
    final groups = await _lib.categories(kind: ItemKind.live);
    if (!mounted || groups.isEmpty) return;
    setState(() => _groups = groups);
    await _selectGroup(groups.first);
  }

  Future<void> _selectGroup(CategoryInfo g) async {
    final items = await _lib.items(
      kind: ItemKind.live,
      category: g.id,
      limit: _maxChannels,
      offset: 0,
    );
    if (!mounted) return;
    setState(() {
      _group = g;
      _channels = items;
      _pages.clear();
    });
    if (_v.hasClients) _v.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToStart());
  }

  /// Today: half an hour before now; other days: the evening.
  void _jumpToStart() {
    final now = DateTime.now();
    final isToday = _day == _today();
    _jumpTo(isToday ? now.subtract(const Duration(minutes: 30)) : _at(18, 0));
  }

  DateTime _at(int h, int m) => DateTime(_day.year, _day.month, _day.day, h, m);

  void _jumpTo(DateTime t) {
    if (!_h.hasClients) return;
    final x = (floorToHalfHour(t) - _from) / 60 * _pxPerMin(context);
    _h.jumpTo(x.clamp(0, _h.position.maxScrollExtent));
  }

  void _setDay(DateTime d, {DateTime? at}) {
    setState(() {
      _day = d;
      _pages.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => at == null ? _jumpToStart() : _jumpTo(at),
    );
  }

  /// The rows of channel [i]'s page (loaded on first need).
  GuideRow? _row(int i) {
    final page = i ~/ _page;
    final rows = _pages[page];
    if (rows != null) return rows[i - page * _page];
    if (_loading.add(page)) {
      final keys = [
        for (final c in _channels.skip(page * _page).take(_page)) c.key,
      ];
      final day = _day;
      _lib.guideWindow(keys: keys, from: _from, to: _to).then((r) {
        _loading.remove(page);
        if (mounted && day == _day) setState(() => _pages[page] = r);
      });
    }
    return null;
  }

  Future<void> _openProgramme(ProgrammeInfo p, ItemInfo channel) async {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final running = p.start <= now && now < p.stop;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Tokens.space * 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(p.title, style: text.titleLarge),
                if (p.subTitle.isNotEmpty || p.episode.isNotEmpty)
                  Text(
                    [
                      p.subTitle,
                      p.episode,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: text.titleSmall,
                  ),
                const SizedBox(height: Tokens.space),
                Text(
                  '${channel.name} · ${programmeWhen(l10n, locale, p)}',
                  style: text.bodyMedium,
                ),
                if (p.category.isNotEmpty)
                  Text(p.category, style: text.bodySmall),
                if (p.desc.isNotEmpty) ...[
                  const SizedBox(height: Tokens.space),
                  Text(p.desc, style: text.bodyMedium),
                ],
                const SizedBox(height: Tokens.space * 2),
                FilledButton.icon(
                  key: const Key('guide.sheet.watch'),
                  autofocus: true,
                  icon: const Icon(Icons.play_arrow),
                  // Past and future programmes play the channel live for now; catch-up and reminders come later.
                  label: Text(
                    running ? l10n.guideWatch : l10n.guideWatchChannel,
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    openItem(
                      this.context,
                      widget.session,
                      channel,
                      channels: _channels,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _dayLabel(AppLocalizations l10n, String locale, DateTime d) {
    final diff = d.difference(_today()).inDays;
    return switch (diff) {
      -1 => l10n.dayYesterday,
      0 => l10n.dayToday,
      1 => l10n.dayTomorrow,
      _ => DateFormat('E d.M.', locale).format(d),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final px = _pxPerMin(context);
    final narrow = MediaQuery.sizeOf(context).width < Tokens.wideLayout;
    final columnWidth = narrow ? 112.0 : 200.0;
    final rowHeight = narrow ? 56.0 : 64.0;
    final width = (_to - _from) / 60 * px;
    final days = guideDays(DateTime.now(), ahead: Session.guideDaysAhead);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowX = now >= _from && now < _to ? (now - _from) / 60 * px : null;

    final controls = Wrap(
      spacing: Tokens.space,
      runSpacing: Tokens.space,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_groups.isNotEmpty)
          DropdownButton<CategoryInfo>(
            key: const Key('guide.group'),
            value: _group,
            items: [
              for (final g in _groups)
                DropdownMenuItem(value: g, child: Text(g.name)),
            ],
            onChanged: (g) => g == null ? null : _selectGroup(g),
          ),
        OutlinedButton(
          key: const Key('guide.now'),
          onPressed: () => _setDay(
            _today(),
            at: DateTime.now().subtract(const Duration(minutes: 30)),
          ),
          child: Text(l10n.programmeNow),
        ),
        OutlinedButton(
          key: const Key('guide.prime'),
          onPressed: () => _jumpTo(_at(20, 15)),
          child: const Text('20:15'),
        ),
        DropdownButton<DateTime>(
          key: const Key('guide.day'),
          value: _day,
          items: [
            for (final d in days)
              DropdownMenuItem(
                value: d,
                child: Text(_dayLabel(l10n, locale, d)),
              ),
          ],
          onChanged: (d) => d == null ? null : _setDay(d),
        ),
      ],
    );

    // The focused programme, above the grid (what the cell can't show: the full title, time and description).
    final header = ValueListenableBuilder<(ProgrammeInfo, ItemInfo)?>(
      valueListenable: _focused,
      builder: (context, f, _) {
        final text = Theme.of(context).textTheme;
        return SizedBox(
          height: narrow ? 48 : 64,
          child: f == null
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${f.$1.title} · ${programmeWhen(l10n, locale, f.$1)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    if (!narrow && f.$1.desc.isNotEmpty)
                      Text(
                        f.$1.desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                  ],
                ),
        );
      },
    );

    final ruler = SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(width: columnWidth),
          Expanded(
            child: SingleChildScrollView(
              controller: _ruler,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Row(
                  children: [
                    for (var t = _from; t < _to; t += 1800)
                      SizedBox(
                        width: 30 * px,
                        child: Text(
                          DateFormat.Hm(locale).format(
                            DateTime.fromMillisecondsSinceEpoch(t * 1000),
                          ),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final column = SizedBox(
      width: columnWidth,
      child: ListView.builder(
        controller: _column,
        itemExtent: rowHeight,
        itemCount: _channels.length,
        itemBuilder: (context, i) {
          final c = _channels[i];
          return Row(
            children: [
              Logo(url: c.logo, size: narrow ? 28 : 36, icon: kindIcon(c.kind)),
              const SizedBox(width: Tokens.space),
              Expanded(
                child: Text(
                  c.number == null ? c.name : '${c.number} ${c.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );

    final body = SingleChildScrollView(
      controller: _h,
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: width,
        child: Stack(
          children: [
            ListView.builder(
              controller: _v,
              itemExtent: rowHeight,
              itemCount: _channels.length,
              itemBuilder: (context, i) => _GuideRowView(
                scroll: _h,
                programmes: _row(i)?.programmes ?? const [],
                from: _from,
                to: _to,
                pxPerMin: px,
                now: now,
                onFocus: (p) => _focused.value = (p, _channels[i]),
                onOpen: (p) => _openProgramme(p, _channels[i]),
              ),
            ),
            if (nowX != null)
              Positioned(
                left: nowX,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    width: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(Tokens.space),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          controls,
          const SizedBox(height: Tokens.space),
          header,
          ruler,
          Expanded(
            child: _channels.isEmpty
                ? Center(child: Text(l10n.guideEmpty))
                : Row(
                    children: [
                      column,
                      Expanded(child: body),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One channel's programmes as cells; running programmes are tinted. A title sticks to the visible left edge, so a
/// programme that began before the scrolled-to time still shows its title (the usual case at "Now").
class _GuideRowView extends StatelessWidget {
  const _GuideRowView({
    required this.scroll,
    required this.programmes,
    required this.from,
    required this.to,
    required this.pxPerMin,
    required this.now,
    required this.onFocus,
    required this.onOpen,
  });
  final ScrollController scroll;
  final List<ProgrammeInfo> programmes;
  final int from, to, now;
  final double pxPerMin;
  final void Function(ProgrammeInfo) onFocus;
  final void Function(ProgrammeInfo) onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, _) => Stack(
        children: [
          for (final p in programmes)
            if (cellGeometry(p.start, p.stop, from, to, pxPerMin) case final g?)
              Positioned(
                left: g.left,
                width: g.width,
                top: 2,
                bottom: 2,
                child: Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Material(
                    color: p.start <= now && now < p.stop
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(Tokens.radius / 2),
                    child: InkWell(
                      key: Key('guide.cell.${p.id}'),
                      borderRadius: BorderRadius.circular(Tokens.radius / 2),
                      onFocusChange: (f) => f ? onFocus(p) : null,
                      onHover: (h) => h ? onFocus(p) : null,
                      onTap: () => onOpen(p),
                      child: Padding(
                        padding: EdgeInsets.only(
                          // The part left of the view; 32 px stay for the text.
                          left:
                              Tokens.space +
                              ((scroll.hasClients ? scroll.offset : 0) - g.left)
                                  .clamp(
                                    0.0,
                                    (g.width - 32).clamp(0.0, double.infinity),
                                  ),
                          right: Tokens.space,
                          top: Tokens.space / 2,
                          bottom: Tokens.space / 2,
                        ),
                        child: Text(
                          p.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
