// How a section's items are shown (owner decision): compact list, list (logo, number, name, what's on now with its
// progress, what's next), tiles, large tiles. Chosen per section in Settings → Lists, switched with the list bar's
// toggle; stored as the profile setting `list_mode_<kind>`. These widgets take plain data, so tests need no core.
// Favourites: a star on every row and tile, a long press, or a long OK on the remote (LongOk) toggles one.
// On a channel the long press or long OK opens its menu instead (showChannelMenu).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'logo.dart';
import 'search_text.dart';

enum ListMode { compact, list, tiles, largeTiles }

/// The profile setting that holds a section's mode.
String listModeSetting(ItemKind kind) => 'list_mode_${kind.name}';

/// Live TV starts as a list (now/next matters there); movies and series as tiles (posters).
ListMode defaultListMode(ItemKind kind) =>
    kind == ItemKind.live ? ListMode.list : ListMode.tiles;

ListMode parseListMode(String? v, ItemKind kind) => ListMode.values.firstWhere(
  (m) => m.name == v,
  orElse: () => defaultListMode(kind),
);

String listModeLabel(AppLocalizations l10n, ListMode m) => switch (m) {
  ListMode.compact => l10n.listModeCompact,
  ListMode.list => l10n.listModeList,
  ListMode.tiles => l10n.listModeTiles,
  ListMode.largeTiles => l10n.listModeLargeTiles,
};

IconData listModeIcon(ListMode m) => switch (m) {
  ListMode.compact => Icons.view_headline,
  ListMode.list => Icons.view_list,
  ListMode.tiles => Icons.grid_view,
  ListMode.largeTiles => Icons.view_module,
};

/// The order of a list (owner decision): provider order (the default), by name both ways, channel number (live),
/// year, recently added and rating (movies and series; added and rating only Xtream Codes sends). Chosen with the
/// list's sort button, remembered per section for its groups and its items (profile settings
/// `sort_<kind>_groups` / `sort_<kind>_items`; the core maps the value to a fixed ORDER BY, `db::Sort`).
/// Favourites, zapping and the guide's channels follow the items' order.
enum ListSort {
  provider('provider'),
  nameAsc('name_asc'),
  nameDesc('name_desc'),
  number('number'),
  yearDesc('year_desc'),
  yearAsc('year_asc'),
  added('added'),
  rating('rating');

  const ListSort(this.value);

  /// The setting's value, as the core parses it.
  final String value;
}

String sortSetting(ItemKind kind, {required bool groups}) =>
    'sort_${kind.name}_${groups ? 'groups' : 'items'}';

ListSort parseSort(String? v) => ListSort.values.firstWhere(
  (s) => s.value == v,
  orElse: () => ListSort.provider,
);

/// The orders that make sense for a list: groups only by name; numbers only for channels; years, dates and ratings
/// only for movies and series, dates and ratings only where the source sends them (Xtream Codes).
List<ListSort> sortOptions(
  ItemKind kind, {
  required bool groups,
  required bool xtream,
}) => [
  ListSort.provider,
  ListSort.nameAsc,
  ListSort.nameDesc,
  if (!groups && kind == ItemKind.live) ListSort.number,
  if (!groups && kind != ItemKind.live) ...[
    ListSort.yearDesc,
    ListSort.yearAsc,
    if (xtream) ...[ListSort.added, ListSort.rating],
  ],
];

String sortLabel(AppLocalizations l10n, ListSort s) => switch (s) {
  ListSort.provider => l10n.sortProvider,
  ListSort.nameAsc => l10n.sortNameAsc,
  ListSort.nameDesc => l10n.sortNameDesc,
  ListSort.number => l10n.sortNumber,
  ListSort.yearDesc => l10n.sortYearDesc,
  ListSort.yearAsc => l10n.sortYearAsc,
  ListSort.added => l10n.sortAdded,
  ListSort.rating => l10n.sortRating,
};

/// The sort button of a list's top bar: a menu of [options] with the current one checked.
class SortButton extends StatelessWidget {
  const SortButton({
    super.key,
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final ListSort value;
  final List<ListSort> options;
  final ValueChanged<ListSort> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<ListSort>(
      key: const Key('list.sort'),
      tooltip: l10n.sortTooltip,
      icon: const Icon(Icons.sort),
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final s in options)
          CheckedPopupMenuItem(
            key: Key('sort.${s.value}'),
            value: s,
            checked: s == value,
            child: Text(sortLabel(l10n, s)),
          ),
      ],
    );
  }
}

IconData kindIcon(ItemKind k) => switch (k) {
  ItemKind.live => Icons.live_tv,
  ItemKind.movie => Icons.movie_outlined,
  ItemKind.series => Icons.video_library_outlined,
  ItemKind.episode => Icons.play_circle_outline,
};

/// How far the programme has run, 0…1.
double progressOf(ProgrammeInfo p, DateTime now) {
  final t = now.millisecondsSinceEpoch / 1000;
  return ((t - p.start) / (p.stop - p.start)).clamp(0.0, 1.0);
}

/// The items of one group, or search results, in [mode]: a list for the list modes, a grid for the tile modes.
/// [nowNext] holds what is on for live items (missing: no guide); [onNearEnd] loads the next page.
/// Search results add [leading] and [trailing] slivers (matching groups, programmes, the "Also in" line), bold the
/// [highlight] query in names and show each item's group.
class ItemsView extends StatelessWidget {
  const ItemsView({
    super.key,
    required this.mode,
    required this.items,
    required this.nowNext,
    required this.onTap,
    required this.now,
    this.loading = false,
    this.onNearEnd,
    this.leading = const [],
    this.trailing = const [],
    this.highlight,
    this.favourites = const {},
    this.onFavourite,
    this.watched = const {},
  });
  final ListMode mode;
  final List<ItemInfo> items;
  final Map<String, NowNext> nowNext;
  final void Function(ItemInfo) onTap;
  final DateTime now;
  final bool loading;
  final VoidCallback? onNearEnd;
  final List<Widget> leading;
  final List<Widget> trailing;
  final String? highlight;

  /// The favourites' keys (filled stars); [onFavourite] toggles one (null: no stars).
  final Set<String> favourites;
  final void Function(ItemInfo)? onFavourite;

  /// The watched movies' and episodes' keys (a check mark).
  final Set<String> watched;

  @override
  Widget build(BuildContext context) {
    final count = items.length + (loading ? 1 : 0);
    Widget cell(BuildContext context, int i) {
      if (i == items.length) {
        return mode == ListMode.compact || mode == ListMode.list
            ? const SkeletonRow()
            : const Skeleton();
      }
      final it = items[i];
      final nn = nowNext[it.key];
      final fav = onFavourite == null ? null : () => onFavourite!(it);
      final hold = fav == null || it.kind != ItemKind.live
          ? fav
          : () => showChannelMenu(
              context,
              it,
              favourite: favourites.contains(it.key),
              onWatch: () => onTap(it),
              onFavourite: fav,
            );
      final cellWidget = switch (mode) {
        ListMode.compact || ListMode.list => ItemRow(
          item: it,
          nowNext: nn,
          compact: mode == ListMode.compact,
          now: now,
          onTap: () => onTap(it),
          highlight: highlight,
          favourite: favourites.contains(it.key),
          onFavourite: fav,
          watched: watched.contains(it.key),
          onHold: hold,
        ),
        _ => ItemCard(
          item: it,
          nowNext: nn,
          large: mode == ListMode.largeTiles,
          onTap: () => onTap(it),
          highlight: highlight,
          favourite: favourites.contains(it.key),
          onFavourite: fav,
          watched: watched.contains(it.key),
          onHold: hold,
        ),
      };
      return hold == null
          ? cellWidget
          : LongOk(onTap: () => onTap(it), onLong: hold, child: cellWidget);
    }

    final body = switch (mode) {
      ListMode.compact ||
      ListMode.list => SliverList.builder(itemCount: count, itemBuilder: cell),
      _ => SliverPadding(
        padding: const EdgeInsets.all(Tokens.space),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: mode == ListMode.largeTiles ? 240 : 160,
            // Posters are portrait (2:3) with their texts on the picture; channel logos sit in a squarer tile
            // with the name below. Search results add a line for the group.
            childAspectRatio:
                (items.isNotEmpty && items.first.kind != ItemKind.live
                    ? 2 / 3
                    : 1 / 1.15) *
                (highlight == null ? 1 : 0.9),
            crossAxisSpacing: Tokens.space,
            mainAxisSpacing: Tokens.space,
          ),
          itemCount: count,
          itemBuilder: cell,
        ),
      ),
    };
    final view = CustomScrollView(slivers: [...leading, body, ...trailing]);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600) onNearEnd?.call();
        return false;
      },
      child: view,
    );
  }
}

/// A row: compact (small logo, number, name) or list (logo, number, name, now + progress, next).
class ItemRow extends StatelessWidget {
  const ItemRow({
    super.key,
    required this.item,
    required this.nowNext,
    required this.compact,
    required this.now,
    required this.onTap,
    this.highlight,
    this.favourite = false,
    this.onFavourite,
    this.watched = false,
    this.onHold,
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool compact;
  final bool favourite;
  final VoidCallback? onFavourite;
  final bool watched;

  /// A long press.
  final VoidCallback? onHold;
  final DateTime now;
  final VoidCallback onTap;

  /// A search result: the query to bold; the group's name shows too.
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = nowNext?.now;
    final next = nowNext?.next;
    // No channel number in front (owner decision: not important); sorting and search by number stay.
    final name = item.name;
    final group = highlight != null && item.group.isNotEmpty
        ? Text(
            item.group,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall,
          )
        : null;
    return ListTile(
      key: Key('item.${item.key}'),
      dense: compact,
      leading: Logo(
        url: item.logo,
        size: compact ? 32 : 48,
        icon: kindIcon(item.kind),
      ),
      title: highlight == null
          ? Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)
          : Text.rich(
              highlightSpan(name, highlight!, null),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      subtitle: compact || (current == null && next == null)
          ? group
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ?group,
                if (current != null) ...[
                  Text(
                    current.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Tokens.space / 2),
                  LinearProgressIndicator(
                    value: progressOf(current, now),
                    minHeight: 3,
                  ),
                ],
                if (next != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Tokens.space / 2),
                    child: Text(
                      next.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
              ],
            ),
      trailing: onFavourite == null && !watched
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (watched) const WatchedMark(),
                if (onFavourite != null)
                  FavouriteStar(
                    item: item,
                    on: favourite,
                    onPressed: onFavourite!,
                  ),
              ],
            ),
      onTap: onTap,
      onLongPress: onHold,
    );
  }
}

/// A channel's menu (long press or long OK; in the guide also a tap on the channel): watch it, or add it to or remove
/// it from the favourites. Nothing has the focus at first: an OK still held would press it.
Future<void> showChannelMenu(
  BuildContext context,
  ItemInfo channel, {
  required bool favourite,
  required VoidCallback onWatch,
  required VoidCallback onFavourite,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (context) {
    final l10n = AppLocalizations.of(context);
    Widget entry(String key, IconData icon, String label, VoidCallback run) =>
        ListTile(
          key: Key('channel.$key'),
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.of(context).pop();
            run();
          },
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            entry('watch', Icons.play_arrow, l10n.guideWatch, onWatch),
            entry(
              'favourite',
              favourite ? Icons.star : Icons.star_border,
              favourite ? l10n.favouriteRemove : l10n.favouriteAdd,
              onFavourite,
            ),
          ],
        ),
      ),
    );
  },
);

/// The star on a row or tile: filled for a favourite.
class FavouriteStar extends StatelessWidget {
  const FavouriteStar({
    super.key,
    required this.item,
    required this.on,
    required this.onPressed,
  });
  final ItemInfo item;
  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      key: Key('item.star.${item.key}'),
      tooltip: on ? l10n.favouriteRemove : l10n.favouriteAdd,
      icon: Icon(on ? Icons.star : Icons.star_border),
      color: on ? Theme.of(context).colorScheme.primary : null,
      onPressed: onPressed,
    );
  }
}

/// OK on a remote (Enter, Select): a short press opens, holding it half a second toggles the favourite. Ahead of the
/// list's own activation, which would open the item on the key going down.
class LongOk extends StatefulWidget {
  const LongOk({
    super.key,
    required this.onTap,
    required this.onLong,
    required this.child,
  });
  final VoidCallback onTap;
  final VoidCallback onLong;
  final Widget child;

  @override
  State<LongOk> createState() => _LongOkState();
}

class _LongOkState extends State<LongOk> {
  static const _holdFor = Duration(milliseconds: 500);
  static final _ok = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };
  Timer? _hold;
  bool _down = false;
  bool _long = false;

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (!_ok.contains(e.logicalKey)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _down = true;
      _long = false;
      _hold?.cancel();
      _hold = Timer(_holdFor, () {
        _long = true;
        widget.onLong();
      });
    } else if (e is KeyUpEvent) {
      _hold?.cancel();
      if (_down && !_long) widget.onTap();
      _down = false;
    }
    return KeyEventResult
        .handled; // repeats too: held OK must not open the item over and over
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _key,
    child: widget.child,
  );
}

/// A tile: the logo or poster, the name, and for live channels what is on now.
class ItemCard extends StatefulWidget {
  const ItemCard({
    super.key,
    required this.item,
    required this.nowNext,
    required this.large,
    required this.onTap,
    this.highlight,
    this.favourite = false,
    this.onFavourite,
    this.watched = false,
    this.onHold,
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool large;
  final bool favourite;
  final VoidCallback? onFavourite;
  final bool watched;

  /// A long press.
  final VoidCallback? onHold;
  final VoidCallback onTap;

  /// A search result: the query to bold; the group's name shows too.
  final String? highlight;

  @override
  State<ItemCard> createState() => _ItemCardState();
}

/// A tile (owner decision: the cinematic look): movies and series as edge-to-edge posters with the name on a dark
/// gradient at the bottom; channels as their logo on a plate with the name below. A focused (D-pad, Tab) or hovered
/// tile lifts: 5 % larger with a shadow (none with reduced motion, where it only gets the focus colour).
class _ItemCardState extends State<ItemCard> {
  bool _lifted = false;

  void _lift(bool on) {
    if (on != _lifted) setState(() => _lifted = on);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final current = widget.nowNext?.now;
    final poster = item.kind != ItemKind.live;
    final still = MediaQuery.disableAnimationsOf(context);
    final star = widget.onFavourite == null
        ? null
        : Positioned(
            top: 0,
            right: 0,
            child: FavouriteStar(
              item: item,
              on: widget.favourite,
              onPressed: widget.onFavourite!,
            ),
          );
    // On a poster the texts are white on the gradient (any picture, either theme); elsewhere the theme's.
    List<Widget> lines({Color? fg, Color? soft}) => [
      Text.rich(
        highlightSpan(item.name, widget.highlight ?? '', null),
        maxLines: widget.large || poster ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: (widget.large ? text.titleSmall : text.bodyMedium)?.copyWith(
          color: fg,
        ),
      ),
      if (widget.highlight != null && item.group.isNotEmpty)
        Text(
          item.group,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: soft),
        ),
      if (current != null)
        Text(
          current.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: soft),
        ),
    ];
    final Widget content;
    if (poster) {
      // The poster fills the tile; the texts sit on a gradient so they read on any picture (white on black).
      content = Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) => Hero(
                tag: 'poster:${item.key}',
                child: Logo(
                  url: item.logo,
                  size: c.maxWidth,
                  icon: kindIcon(item.kind),
                  fill: true,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xE6000000)],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.space,
                  Tokens.space * 3,
                  Tokens.space,
                  Tokens.space,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: lines(fg: Colors.white, soft: Colors.white70),
                ),
              ),
            ),
          ),
          ?star,
          if (widget.watched)
            const Positioned(
              top: Tokens.space,
              left: Tokens.space,
              child: WatchedMark(),
            ),
        ],
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.all(Tokens.space),
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Tokens.radius / 2),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(Tokens.space),
                        child: LayoutBuilder(
                          builder: (context, c) => Center(
                            child: Logo(
                              url: item.logo,
                              size: c.biggest.shortestSide,
                              icon: kindIcon(item.kind),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ?star,
                  ],
                ),
              ),
            ),
            const SizedBox(height: Tokens.space),
            ...lines(),
          ],
        ),
      );
    }
    return AnimatedScale(
      scale: _lifted && !still ? 1.05 : 1,
      duration: still ? Duration.zero : Tokens.motion,
      curve: Curves.easeOutCubic,
      child: Card(
        key: Key('item.${item.key}'),
        clipBehavior: Clip.antiAlias,
        elevation: _lifted ? 8 : 1,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onHold,
          onFocusChange: _lift,
          onHover: _lift,
          child: content,
        ),
      ),
    );
  }
}

/// A placeholder while something loads (docs/DESIGN.md: loading uses skeletons, not spinners): a rounded block in
/// the surface colour that slowly pulses; it stands still with reduced motion.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height});
  final double? width;
  final double? height;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.45,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.value = 1;
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _pulse,
    child: Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Tokens.radius / 2),
      ),
    ),
  );
}

/// A list row's skeleton: the logo's square and two text lines.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(
      horizontal: Tokens.space * 2,
      vertical: Tokens.space,
    ),
    child: Row(
      children: [
        Skeleton(width: 48, height: 48),
        SizedBox(width: Tokens.space * 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(height: 14),
              SizedBox(height: Tokens.space),
              FractionallySizedBox(
                widthFactor: 0.6,
                child: Skeleton(height: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Shown on watched movies and episodes; a dark plate keeps it readable on any poster.
class WatchedMark extends StatelessWidget {
  const WatchedMark({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0x99000000),
      shape: BoxShape.circle,
    ),
    child: Icon(
      Icons.check_circle,
      size: 20,
      color: Colors.white,
      semanticLabel: AppLocalizations.of(context).watchedLabel,
    ),
  );
}
