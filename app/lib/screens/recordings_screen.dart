// Recordings (services/recordings.dart): the list (a group above the TV groups once there are any), the folder setting
// and the notice that a recording will take the connection from what plays.

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/platform_bridge.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';
import 'player_screen.dart';

/// "1.4 GB" / "350 MB": metric, as the owner wants.
String sizeLabel(int bytes) => bytes >= 1000000000
    ? '${(bytes / 1000000000).toStringAsFixed(1)} GB'
    : '${(bytes / 1000000).round()} MB';

class RecordingsScreen extends StatelessWidget {
  const RecordingsScreen({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rec = session.recordings;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.recordings)),
      body: ListenableBuilder(
        listenable: rec,
        builder: (context, _) {
          final list = rec.list();
          if (list.isEmpty) {
            return Center(child: Text(l10n.recordingsEmpty));
          }
          return ListView(
            children: [for (final r in list) _Row(session: session, r: r)],
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.session, required this.r});
  final Session session;
  final RecordingInfo r;

  String _state(AppLocalizations l10n) => switch (r.state) {
    'scheduled' => l10n.recordingScheduled,
    'recording' => l10n.recordingRunning,
    'skipped' => l10n.recordingSkipped,
    'done' => l10n.recordingDone,
    _ => r.message.isEmpty ? l10n.recordingFailed : r.message,
  };

  Future<void> _delete(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    // The one modal the design allows: confirming a destructive action.
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.recordingDeleteConfirm(r.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('recording.deleteConfirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.remove),
          ),
        ],
      ),
    );
    if (ok == true) await session.recordings.delete(r);
  }

  void _play(BuildContext context) {
    final item = ItemInfo(
      key: 'recording:${r.id}',
      kind: ItemKind.movie,
      name: r.title,
      category: '',
      logo: '',
      archiveDays: 0,
      group: '',
    );
    // Like a Premiumize file: played as it is, without continue watching.
    unawaited(session.playUrl(item, r.file));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(session: session, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = l10n.localeName;
    final start = DateTime.fromMillisecondsSinceEpoch(r.start * 1000);
    final when =
        '${DateFormat.MMMd(locale).format(start)} ${DateFormat.Hm(locale).format(start)}';
    final size = r.bytes > BigInt.zero
        ? ' · ${sizeLabel(r.bytes.toInt())}'
        : '';
    return ListTile(
      key: Key('recording.${r.id}'),
      leading: Icon(
        r.state == 'recording'
            ? Icons.fiber_manual_record
            : Icons.video_file_outlined,
        color: r.state == 'recording' ? Colors.red : null,
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$when · ${_state(l10n)}$size', maxLines: 2),
      onTap: r.state == 'done' && r.file.isNotEmpty
          ? () => _play(context)
          : null,
      trailing: r.state == 'recording' || r.state == 'scheduled'
          ? IconButton(
              key: Key('recording.stop.${r.id}'),
              tooltip: l10n.stop,
              icon: const Icon(Icons.stop),
              onPressed: () => session.recordings.stop(r.id),
            )
          : IconButton(
              key: Key('recording.delete.${r.id}'),
              tooltip: l10n.remove,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context),
            ),
    );
  }
}

/// Settings → Playback: where recordings go.
class RecordingsFolderSetting extends StatefulWidget {
  const RecordingsFolderSetting({super.key, required this.session});
  final Session session;

  @override
  State<RecordingsFolderSetting> createState() =>
      _RecordingsFolderSettingState();
}

class _RecordingsFolderSettingState extends State<RecordingsFolderSetting> {
  String _folder = '';

  @override
  void initState() {
    super.initState();
    widget.session.recordings.folder().then((f) {
      if (mounted) setState(() => _folder = f);
    });
  }

  Future<void> _choose() async {
    final rec = widget.session.recordings;
    String? picked;
    if (Platform.isAndroid) {
      picked = await PlatformBridge.pickFolder();
      // A TV without the system's picker: the app's own folder on a drive.
      if (picked == null && mounted) picked = await _appFolder();
    } else {
      picked = await getDirectoryPath();
    }
    if (picked == null || picked.isEmpty) return;
    rec.setFolder(picked);
    setState(() => _folder = picked!);
  }

  Future<String?> _appFolder() async {
    final folders = await PlatformBridge.appFolders();
    if (!mounted) return null;
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(l10n.recordingsAppFolders)),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.sd_storage_outlined),
                title: Text(f),
                onTap: () => Navigator.pop(context, f),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // A content URI says nothing to a person: its last part names the folder.
    final shown = _folder.startsWith('content://')
        ? Uri.decodeComponent(_folder.split('/').last)
        : _folder;
    return ListTile(
      key: const Key('settings.recordingsFolder'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(l10n.recordingsFolder),
      subtitle: Text(shown),
      trailing: TextButton(onPressed: _choose, child: Text(l10n.choose)),
    );
  }
}

/// On top of every screen a minute before a recording takes the connection: Skip keeps what plays.
class RecordingConflict extends StatelessWidget {
  const RecordingConflict({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<({int id, String title})?>(
      valueListenable: session.recordings.conflict,
      builder: (context, c, _) => c == null
          ? const SizedBox.shrink()
          : MaterialBanner(
              key: const Key('recording.conflict'),
              padding: const EdgeInsets.all(Tokens.space),
              content: Text(l10n.recordingConflict(c.title)),
              actions: [
                TextButton(
                  key: const Key('recording.skip'),
                  onPressed: () => session.recordings.skip(c.id),
                  child: Text(l10n.recordingSkip),
                ),
              ],
            ),
    );
  }
}
