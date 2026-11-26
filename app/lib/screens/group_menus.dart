// The menus of the user's own order (core: groups.rs): a group's (rename, move, delete an own one) and an item's extra
// entries (add to an own group, rename; inside an own group also move and remove). All are bottom sheets; moves are
// entries rather than dragging, so a D-pad reaches them.
// Debugging: the lists reload on Session.groupsChanged, which every change here ends with.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

bool isOwnGroup(String category) => category.startsWith('custom:');

/// [ids] with the one at [from] moved by [by] places, or null when it can't move there.
List<String>? moved(List<String> ids, int from, int by) {
  final to = from + by;
  if (from < 0 || to < 0 || to >= ids.length) return null;
  return [...ids]
    ..removeAt(from)
    ..insert(to, ids[from]);
}

typedef MenuEntry = ({
  String key,
  IconData icon,
  String label,
  VoidCallback run,
});

Future<void> _sheet(
  BuildContext context,
  String title,
  List<MenuEntry> entries,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final e in entries)
            ListTile(
              key: Key('menu.${e.key}'),
              leading: Icon(e.icon),
              title: Text(e.label),
              onTap: () {
                Navigator.of(context).pop();
                e.run();
              },
            ),
        ],
      ),
    ),
  ),
);

/// Asks for a name; null when cancelled.
Future<String?> askName(BuildContext context, String title, String initial) {
  final field = TextEditingController(text: initial);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        // Above the keyboard.
        padding: EdgeInsets.fromLTRB(
          Tokens.space * 2,
          Tokens.space * 2,
          Tokens.space * 2,
          Tokens.space * 2 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('name.field'),
                controller: field,
                autofocus: true,
                decoration: InputDecoration(labelText: title),
                onSubmitted: (v) => Navigator.of(context).pop(v),
              ),
            ),
            const SizedBox(width: Tokens.space),
            FilledButton(
              key: const Key('name.save'),
              onPressed: () => Navigator.of(context).pop(field.text),
              child: Text(AppLocalizations.of(context).save),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(() => Future.delayed(Tokens.motion * 2, field.dispose));
}

/// A group's menu; [groups] as shown, so moving knows its neighbours (own groups stay above the provider's).
Future<void> showGroupMenu(
  BuildContext context,
  Session session,
  ItemKind kind,
  CategoryInfo group,
  List<CategoryInfo> groups,
) {
  final l10n = AppLocalizations.of(context);
  final lib = session.library!;
  final own = isOwnGroup(group.id);
  final peers = [
    for (final g in groups)
      if (isOwnGroup(g.id) == own) g.id,
  ];
  final at = peers.indexOf(group.id);
  Future<void> order(List<String> ids) async {
    await lib.setGroupOrder(kind: kind, ids: ids);
    session.groupsChanged();
  }

  return _sheet(context, group.name, [
    (
      key: 'rename',
      icon: Icons.edit_outlined,
      label: l10n.rename,
      run: () async {
        final name = await askName(context, l10n.renameHint, group.name);
        if (name == null) return;
        await lib.renameGroup(kind: kind, category: group.id, name: name);
        session.groupsChanged();
      },
    ),
    if (moved(peers, at, -1) case final ids?)
      (
        key: 'up',
        icon: Icons.arrow_upward,
        label: l10n.moveUp,
        run: () => order(ids),
      ),
    if (moved(peers, at, 1) case final ids?)
      (
        key: 'down',
        icon: Icons.arrow_downward,
        label: l10n.moveDown,
        run: () => order(ids),
      ),
    if (moved(peers, at, -at) case final ids? when at > 1)
      (
        key: 'top',
        icon: Icons.vertical_align_top,
        label: l10n.moveTop,
        run: () => order(ids),
      ),
    if (own)
      (
        key: 'delete',
        icon: Icons.delete_outline,
        label: l10n.groupDelete,
        run: () async {
          await lib.deleteGroup(category: group.id);
          session.groupsChanged();
        },
      ),
  ]);
}

/// An item's extra entries. [group]: the own group it is shown in with its items' keys in order, or null.
List<MenuEntry> itemMenu(
  BuildContext context,
  Session session,
  ItemInfo item, {
  ({String id, List<String> keys})? group,
}) {
  final l10n = AppLocalizations.of(context);
  final lib = session.library!;
  Future<void> order(List<String> keys) async {
    await lib.setItemOrder(category: group!.id, keys: keys);
    session.groupsChanged();
  }

  final at = group?.keys.indexOf(item.key) ?? -1;
  return [
    (
      key: 'addToGroup',
      icon: Icons.playlist_add,
      label: l10n.groupAdd,
      run: () => _addToGroup(context, session, item),
    ),
    if (item.kind == ItemKind.live)
      (
        key: 'rename',
        icon: Icons.edit_outlined,
        label: l10n.rename,
        run: () async {
          final name = await askName(context, l10n.renameHint, item.name);
          if (name == null) return;
          await lib.renameItem(key: item.key, name: name);
          session.groupsChanged();
        },
      ),
    if (group != null) ...[
      if (moved(group.keys, at, -1) case final keys?)
        (
          key: 'up',
          icon: Icons.arrow_upward,
          label: l10n.moveUp,
          run: () => order(keys),
        ),
      if (moved(group.keys, at, 1) case final keys?)
        (
          key: 'down',
          icon: Icons.arrow_downward,
          label: l10n.moveDown,
          run: () => order(keys),
        ),
      (
        key: 'remove',
        icon: Icons.playlist_remove,
        label: l10n.groupRemove,
        run: () async {
          await lib.setGroupMember(
            category: group.id,
            key: item.key,
            member: false,
          );
          session.groupsChanged();
        },
      ),
    ],
  ];
}

Future<void> _addToGroup(
  BuildContext context,
  Session session,
  ItemInfo item,
) async {
  final l10n = AppLocalizations.of(context);
  final lib = session.library!;
  // A series page's episodes belong to no section's groups of their own: they go with the series.
  final kind = item.kind == ItemKind.episode ? ItemKind.series : item.kind;
  final own = [
    for (final g in await lib.categories(kind: kind, sort: 'provider'))
      if (isOwnGroup(g.id)) g,
  ];
  if (!context.mounted) return;
  Future<void> add(String id) async {
    await lib.setGroupMember(category: id, key: item.key, member: true);
    session.groupsChanged();
  }

  await _sheet(context, l10n.groupAdd, [
    for (final g in own)
      (
        key: 'group.${g.id}',
        icon: Icons.folder_outlined,
        label: g.name,
        run: () => add(g.id),
      ),
    (
      key: 'group.new',
      icon: Icons.create_new_folder_outlined,
      label: l10n.groupNew,
      run: () async {
        final name = await askName(context, l10n.groupNew, '');
        if (name == null || name.trim().isEmpty) return;
        await add(await lib.createGroup(kind: kind, name: name));
      },
    ),
  ]);
}
