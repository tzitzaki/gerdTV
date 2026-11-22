// How a section's items are shown (owner decision): compact list, list (logo, number, name, what's on now with its
// progress, what's next), tiles, large tiles. Chosen per section in Settings → Lists, switched with the list bar's
// toggle; stored as the profile setting `list_mode_<kind>`. These widgets take plain data, so tests need no core.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'logo.dart';

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

/// The items of one group in [mode]: a list for the list modes, a grid for the tile modes.
/// [nowNext] holds what is on for live items (missing: no guide); [onNearEnd] loads the next page.
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
  });
  final ListMode mode;
  final List<ItemInfo> items;
  final Map<String, NowNext> nowNext;
  final void Function(ItemInfo) onTap;
  final DateTime now;
  final bool loading;
  final VoidCallback? onNearEnd;

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
      return switch (mode) {
        ListMode.compact || ListMode.list => ItemRow(
          item: it,
          nowNext: nn,
          compact: mode == ListMode.compact,
          now: now,
          onTap: () => onTap(it),
        ),
        _ => ItemCard(
          item: it,
          nowNext: nn,
          large: mode == ListMode.largeTiles,
          onTap: () => onTap(it),
        ),
      };
    }

    final view = switch (mode) {
      ListMode.compact ||
      ListMode.list => ListView.builder(itemCount: count, itemBuilder: cell),
      _ => GridView.builder(
        padding: const EdgeInsets.all(Tokens.space),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: mode == ListMode.largeTiles ? 240 : 160,
          // Posters are portrait (2:3); channel logos sit in a squarer tile with the name below.
          childAspectRatio:
              items.isNotEmpty && items.first.kind != ItemKind.live
              ? 2 / 3.6
              : 1 / 1.15,
          crossAxisSpacing: Tokens.space,
          mainAxisSpacing: Tokens.space,
        ),
        itemCount: count,
        itemBuilder: cell,
      ),
    };
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
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool compact;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = nowNext?.now;
    final next = nowNext?.next;
    return ListTile(
      key: Key('item.${item.key}'),
      dense: compact,
      leading: Logo(
        url: item.logo,
        size: compact ? 32 : 48,
        icon: kindIcon(item.kind),
      ),
      title: Text(
        item.number == null ? item.name : '${item.number}  ${item.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: compact || (current == null && next == null)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
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
      onTap: onTap,
    );
  }
}

/// A tile: the logo or poster, the name, and for live channels what is on now.
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.item,
    required this.nowNext,
    required this.large,
    required this.onTap,
  });
  final ItemInfo item;
  final NowNext? nowNext;
  final bool large;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = nowNext?.now;
    return Card(
      key: Key('item.${item.key}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Tokens.space),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) => Logo(
                    url: item.logo,
                    size: c.biggest.shortestSide,
                    icon: kindIcon(item.kind),
                  ),
                ),
              ),
              const SizedBox(height: Tokens.space),
              Text(
                item.name,
                maxLines: large ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: large ? text.titleSmall : text.bodyMedium,
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
