// One row in every list (browse, episodes, search): logo or poster, name, group, channel number.
// Logos come from the core's disk cache (logo.dart).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'list_modes.dart';
import 'logo.dart';

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.title,
    this.watched = false,
    this.onWatched,
  });
  final ItemInfo item;
  final VoidCallback onTap;
  final String? subtitle;

  /// Shown instead of the item's name (search shows a programme's title on its channel's tile).
  final String? title;

  /// Episodes: the check mark, which marks or unmarks it (null: none).
  final bool watched;
  final VoidCallback? onWatched;

  @override
  Widget build(BuildContext context) {
    final logo = Logo(url: item.logo, size: 48, icon: kindIcon(item.kind));
    return ListTile(
      leading: logo,
      title: Text(
        title ?? item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Tokens.space * 2,
        vertical: Tokens.space / 2,
      ),
      trailing: onWatched == null
          ? null
          : WatchedButton(item: item, watched: watched, onPressed: onWatched!),
      onTap: onTap,
    );
  }
}

/// The watched check mark: filled once watched; a tap marks or unmarks.
class WatchedButton extends StatelessWidget {
  const WatchedButton({
    super.key,
    required this.item,
    required this.watched,
    required this.onPressed,
  });
  final ItemInfo item;
  final bool watched;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      key: Key('watched.${item.key}'),
      tooltip: watched ? l10n.watchedUnmark : l10n.watchedMark,
      isSelected: watched,
      icon: const Icon(Icons.check_circle_outline),
      selectedIcon: const Icon(Icons.check_circle),
      onPressed: onPressed,
    );
  }
}
