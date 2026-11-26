// Google Cast in the app (services/casting.dart): the device picker from the player, and the bar that remote-controls
// what casts (below every screen, like the now-playing bar).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/casting.dart';
import '../services/session.dart';
import '../src/rust/api/cast.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/library.dart' as lib show appSetting, setAppSetting;
import '../theme.dart';

/// Devices on the network; a tap casts [item] there (the player then closes: it plays over there).
Future<void> showCastSheet(
  BuildContext context,
  Session session,
  ItemInfo item,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _CastSheet(session: session, item: item),
);

class _CastSheet extends StatefulWidget {
  const _CastSheet({required this.session, required this.item});
  final Session session;
  final ItemInfo item;

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  late Future<List<CastDeviceInfo>> _found = widget.session.casting.find();
  String? _error;
  bool _busy = false;

  bool get _noted {
    final dir = widget.session.appDir;
    return dir == null ||
        lib.appSetting(dir: dir, key: settingCastNoted) == '1';
  }

  Future<void> _cast(CastDeviceInfo d) async {
    final dir = widget.session.appDir;
    if (dir != null) {
      lib.setAppSetting(dir: dir, key: settingCastNoted, value: '1');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.casting.start(d, widget.item);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(); // the sheet
      nav.maybePop(); // the player: it plays over there now
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: FutureBuilder<List<CastDeviceInfo>>(
        future: _found,
        builder: (context, snap) {
          final list = snap.data;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    l10n.castTo,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  subtitle: _noted ? null : Text(l10n.castNotice),
                  trailing: IconButton(
                    key: const Key('cast.search'),
                    tooltip: l10n.castSearch,
                    icon: const Icon(Icons.refresh),
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _found = widget.session.casting.find(),
                          ),
                  ),
                ),
                if (_busy || list == null)
                  const Padding(
                    padding: EdgeInsets.all(Tokens.space * 2),
                    child: LinearProgressIndicator(),
                  )
                else if (snap.hasError || list.isEmpty)
                  ListTile(
                    title: Text(
                      snap.hasError ? '${snap.error}' : l10n.castNone,
                    ),
                  )
                else
                  for (final d in list)
                    ListTile(
                      key: Key('cast.device.${d.host}'),
                      leading: const Icon(Icons.cast),
                      title: Text(d.name),
                      onTap: () => _cast(d),
                    ),
                if (_error != null)
                  ListTile(
                    title: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// What casts, with play/pause and Stop.
class CastBar extends StatelessWidget {
  const CastBar({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final casting = session.casting;
    return ValueListenableBuilder(
      valueListenable: casting.active,
      builder: (context, a, _) => a == null
          ? const SizedBox.shrink()
          : Material(
              key: const Key('cast.bar'),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: SafeArea(
                top: false,
                child: ListTile(
                  leading: const Icon(Icons.cast_connected),
                  title: Text(
                    a.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(l10n.castOn(a.device)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const Key('cast.pause'),
                        tooltip: l10n.menuBarPlayPause,
                        icon: Icon(a.paused ? Icons.play_arrow : Icons.pause),
                        onPressed: casting.togglePause,
                      ),
                      IconButton(
                        key: const Key('cast.stop'),
                        tooltip: l10n.stop,
                        icon: const Icon(Icons.stop),
                        onPressed: casting.stop,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
