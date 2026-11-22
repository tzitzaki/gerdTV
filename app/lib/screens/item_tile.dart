// One row in every list (browse, episodes, search): logo or poster, name, group, channel number.
// Logos load from the provider's URL as given (disk caching by the core comes with the images work).

import 'package:material_ui/material_ui.dart';

import '../src/rust/api/library.dart';
import '../theme.dart';

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
  });
  final ItemInfo item;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      ItemKind.live => Icons.live_tv,
      ItemKind.movie => Icons.movie_outlined,
      ItemKind.series => Icons.video_library_outlined,
      ItemKind.episode => Icons.play_circle_outline,
    };
    final logo = item.logo.startsWith('http')
        ? Image.network(
            item.logo,
            width: 48,
            height: 48,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Icon(icon),
          )
        : Icon(icon);
    return ListTile(
      leading: SizedBox(width: 48, height: 48, child: Center(child: logo)),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: item.number == null
          ? null
          : Text(
              '${item.number}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Tokens.space * 2,
        vertical: Tokens.space / 2,
      ),
      onTap: onTap,
    );
  }
}
