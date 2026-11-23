// Settings → Your data: export the open profile's user data (favourites, recents, reminders, manual guide mapping,
// settings; no secrets) as one JSON file, and import such a file (merged: newer entries win, nothing is deleted;
// gerdtv_core::userdata). Where the file goes: macOS/Linux a save dialog, Android the Downloads folder (phone and
// TV alike; Android TV has no useful share targets), iPhone/iPad the share sheet ("Save to Files"). Import picks
// a file with the system's file picker everywhere.
// Debugging: a refused file shows the core's reason; Android's Downloads write is MainActivity.saveToDownloads.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/platform_bridge.dart';
import '../services/session.dart';

/// The export's file name: `gerdtv-<profile>-<YYYY-MM-DD>.json`, the profile name reduced to safe characters.
String userDataFileName(String profile, DateTime day) {
  final safe = profile.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  final name = safe.replaceAll(RegExp(r'^-+|-+$'), '');
  final date = day.toIso8601String().substring(0, 10);
  return 'gerdtv-${name.isEmpty ? 'profile' : name}-$date.json';
}

const _json = XTypeGroup(
  label: 'JSON',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

class UserDataSettings extends StatefulWidget {
  const UserDataSettings({super.key, required this.session});
  final Session session;

  @override
  State<UserDataSettings> createState() => _UserDataSettingsState();
}

class _UserDataSettingsState extends State<UserDataSettings> {
  bool _busy = false;
  String? _result; // the last action's outcome, shown under the buttons

  Future<void> _run(Future<String?> Function() step) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await step();
      if (r != null) _result = r;
    } catch (e) {
      _result = l10n.userDataFailed('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns the line to show, or null when the user cancelled.
  Future<String?> _export() async {
    final l10n = AppLocalizations.of(context);
    final json = await widget.session.library!.exportUserData();
    final name = userDataFileName(
      widget.session.profile?.name ?? '',
      DateTime.now(),
    );
    if (Platform.isAndroid) {
      return l10n.userDataExportedTo(
        await PlatformBridge.saveToDownloads(name, json),
      );
    }
    if (Platform.isIOS) {
      final file = File('${(await getTemporaryDirectory()).path}/$name');
      await file.writeAsString(json);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: 'application/json')]),
      );
      return null; // the share sheet says itself whether it was saved
    }
    final target = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [_json],
    );
    if (target == null) return null;
    await File(target.path).writeAsString(json);
    return l10n.userDataExportedTo(target.path);
  }

  Future<String?> _import() async {
    final l10n = AppLocalizations.of(context);
    final file = await openFile(acceptedTypeGroups: [_json]);
    if (file == null) return null;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    final n = await widget.session.library!.importUserData(json: text);
    return l10n.userDataImported(n.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          key: const Key('userData.export'),
          leading: const Icon(Icons.upload_file),
          title: Text(l10n.userDataExport),
          subtitle: Text(l10n.userDataExportHint),
          enabled: !_busy,
          onTap: () => _run(_export),
        ),
        ListTile(
          key: const Key('userData.import'),
          leading: const Icon(Icons.download_for_offline_outlined),
          title: Text(l10n.userDataImport),
          subtitle: Text(l10n.userDataImportHint),
          enabled: !_busy,
          onTap: () => _run(_import),
        ),
        if (_result != null)
          ListTile(key: const Key('userData.result'), title: Text(_result!)),
      ],
    );
  }
}
