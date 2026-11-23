// How a section's items are shown (owner decision): compact list, list (logo, number, name, what's on now with its
// progress, what's next), tiles, large tiles. Chosen per section in Settings → Lists, switched with the list bar's
// toggle; stored as the profile setting `list_mode_<kind>`. These widgets take plain data, so tests need no core.
// Favourites: a star on every row and tile, a long press, or a long OK on the remote (LongOk) toggles one.

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

  @override
  Widget build(BuildContext context) {
    final count = items.length + (loading ? 1 : 0);
    Widget cell(BuildContext context, int i) {
      if (i == items.length) {
        return const Padding(
          padding: EdgeInsets.all(Tokens.space * 2),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final it = items[i];
      final nn = nowNext[it.key];
      final fav = onFavourite == null ? null : () => onFavourite!(it);
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
        ),
        _ => ItemCard(
          item: it,
          nowNext: nn,
          large: mode == ListMode.largeTiles,
          onTap: () => onTap(it),
          highlight: highlight,
          favourite: favourites.contains(it.key),
          onFavourite: fav,
        ),
      };
      return fav == null
          ? cellWidget
          : LongOk(onTap: () => onTap(it), onLong: fav, child: cellWidget);
    }

    final body = switch (mode) {
      ListMode.compact ||
      ListMode.list => SliverList.builder(itemCount: count, itemBuilder: cell),
      _ => SliverPadding(
        padding: const EdgeInsets.all(Tokens.space),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: mode == ListMode.largeTiles ? 240 : 160,
            // Posters are portrait (2:3); channel logos sit in a squarer tile with the name below. Search results
            // add a line for the group.
            childAspectRatio:
                (items.isNotEmpty && items.first.kind != ItemKind.live
                    ? 2 / 3.6
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
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool compact;
  final bool favourite;
  final VoidCallback? onFavourite;
  final DateTime now;
  final VoidCallback onTap;

  /// A search result: the query to bold; the group's name shows too.
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = nowNext?.now;
    final next = nowNext?.next;
    final name = item.number == null
        ? item.name
        : '${item.number}  ${item.name}';
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
      trailing: onFavourite == null
          ? null
          : FavouriteStar(item: item, on: favourite, onPressed: onFavourite!),
      onTap: onTap,
      onLongPress: onFavourite,
    );
  }
}

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
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.item,
    required this.nowNext,
    required this.large,
    required this.onTap,
    this.highlight,
    this.favourite = false,
    this.onFavourite,
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool large;
  final bool favourite;
  final VoidCallback? onFavourite;
  final VoidCallback onTap;

  /// A search result: the query to bold; the group's name shows too.
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = nowNext?.now;
    return Card(
      key: Key('item.${item.key}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onFavourite,
        child: Padding(
          padding: const EdgeInsets.all(Tokens.space),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, c) => Logo(
                          url: item.logo,
                          size: c.biggest.shortestSide,
                          icon: kindIcon(item.kind),
                        ),
                      ),
                    ),
                    if (onFavourite != null)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: FavouriteStar(
                          item: item,
                          on: favourite,
                          onPressed: onFavourite!,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Tokens.space),
              Text.rich(
                highlightSpan(item.name, highlight ?? '', null),
                maxLines: large ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: large ? text.titleSmall : text.bodyMedium,
              ),
              if (highlight != null && item.group.isNotEmpty)
                Text(
                  item.group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
              if (current != null)
                Text(
                  current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
