// Settings → Updates: checks the latest release (signed manifest, newer version, a build for this platform; the
// checks are the core's, gerdtv_core::update), shows its notes and downloads the file, kept only when its SHA-256
// matches. Installing: desktop opens the download folder (the macOS swap and Android's installer come next); on
// iPhone/iPad the IPA has to be re-signed first, so there is only a hint.
// Debugging: a failure shows the core's reason (signature, size/SHA-256, network).

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/update.dart';

/// The manifest's platform names.
String get updatePlatform => Platform.isMacOS
    ? 'macos'
    : Platform.isIOS
    ? 'ios'
    : Platform.isAndroid
    ? 'android'
    : 'linux';

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key});

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  bool _busy = false;
  bool _checked = false;
  UpdateInfo? _update;
  String? _file;
  String? _error;

  Future<void> _run(Future<void> Function() step) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await step();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() => _run(() async {
    _update = await checkUpdate(platform: updatePlatform);
    _checked = true;
  });

  Future<void> _download() => _run(() async {
    final dir =
        (isDesktop ? await getDownloadsDirectory() : null) ??
        await getTemporaryDirectory();
    _file = await downloadUpdate(update: _update!, dir: dir.path);
  });

  /// Desktop: the folder with the download, in the system's file manager.
  void _showFolder() {
    final folder = File(_file!).parent.path;
    Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [folder]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final u = _update;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            l10n.settingsUpdates,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          key: const Key('update.check'),
          leading: _busy
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update_alt),
          title: Text(
            _busy && u == null ? l10n.updateChecking : l10n.updateCheck,
          ),
          subtitle: _error != null
              ? Text(l10n.updateFailed(_error!))
              : _checked && u == null
              ? Text(l10n.updateNone)
              : null,
          enabled: !_busy,
          onTap: _check,
        ),
        if (u != null) ...[
          ListTile(
            title: Text(l10n.updateAvailable(u.version)),
            subtitle: u.notes.isEmpty
                ? null
                : Text(u.notes, maxLines: 8, overflow: TextOverflow.ellipsis),
          ),
          if (updatePlatform == 'ios')
            ListTile(title: Text(l10n.updateIosHint))
          else if (_file == null)
            ListTile(
              key: const Key('update.download'),
              leading: const Icon(Icons.download),
              title: Text(_busy ? l10n.updateDownloading : l10n.updateDownload),
              enabled: !_busy,
              onTap: _download,
            )
          else ...[
            ListTile(title: Text(l10n.updateDownloaded(_file!))),
            if (isDesktop)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(l10n.updateShowFolder),
                onTap: _showFolder,
              ),
          ],
        ],
      ],
    );
  }
}
