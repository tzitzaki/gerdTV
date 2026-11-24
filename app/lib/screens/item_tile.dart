// One row in every list (browse, episodes, search): logo or poster, name, group, channel number.
// Logos come from the core's disk cache (logo.dart).

import 'package:material_ui/material_ui.dart';

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
  });
  final ItemInfo item;
  final VoidCallback onTap;
  final String? subtitle;

  /// Shown instead of the item's name (search shows a programme's title on its channel's tile).
  final String? title;

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
      onTap: onTap,
    );
  }
}
