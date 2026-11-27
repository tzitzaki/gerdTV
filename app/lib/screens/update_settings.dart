// Settings → About → Updates: the update service's state and steps (services/updater.dart has the flow and the
// checks: signed manifest, newer version, a build for this platform, the file kept only when its SHA-256 matches).
// Check finds the newest release and shows its notes; then the platform's step: macOS Install and restart (an
// update fetched in the background also goes in when gerdTV quits), Android Install (the system's installer), Linux
// Show in folder, iPhone/iPad the IPA itself (re-signed first). The update bar under the app offers the same.
// Debugging: a failure shows the core's reason (signature, size/SHA-256, network).

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/platform_bridge.dart';
import '../services/session.dart';
import '../services/updater.dart';
import '../src/rust/api/update.dart';

class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final up = session.updater;
    return ListenableBuilder(
      listenable: Listenable.merge([up.available, up.file, up.busy, up.error]),
      builder: (context, _) {
        final u = up.available.value;
        final file = up.file.value;
        final busy = up.busy.value;
        final error = up.error.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // No heading: the settings category "Updates" shows it.
            ListTile(
              key: const Key('update.check'),
              leading: busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
              title: Text(
                busy && u == null ? l10n.updateChecking : l10n.updateCheck,
              ),
              subtitle: error != null
                  ? Text(l10n.updateFailed(error))
                  : up.checked && u == null
                  ? Text(l10n.updateNone)
                  : null,
              enabled: !busy,
              onTap: up.check,
            ),
            if (u != null) ...[
              ListTile(
                title: Text(l10n.updateAvailable(u.version)),
                subtitle: u.notes.isEmpty
                    ? null
                    : Text(
                        u.notes,
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              // iPhone/iPad: no install from inside the app; the browser downloads the IPA itself (the manifest's URL).
              if (updatePlatform == 'ios')
                ListTile(
                  key: const Key('update.ipa'),
                  leading: const Icon(Icons.download),
                  title: Text(l10n.updateIpa),
                  subtitle: Text(l10n.updateIosHint),
                  onTap: () => openOrShow(context, u.url),
                )
              else if (file == null)
                ListTile(
                  key: const Key('update.download'),
                  leading: const Icon(Icons.download),
                  title: Text(
                    busy ? l10n.updateDownloading : l10n.updateDownload,
                  ),
                  enabled: !busy,
                  onTap: up.auto,
                )
              else ...[
                ListTile(title: Text(l10n.updateDownloaded(file))),
                if (Platform.isMacOS || Platform.isAndroid)
                  ListTile(
                    key: const Key('update.install'),
                    leading: const Icon(Icons.install_desktop),
                    title: Text(
                      Platform.isMacOS
                          ? l10n.updateInstallRestart
                          : l10n.updateInstall,
                    ),
                    subtitle: Platform.isMacOS
                        ? Text(l10n.updateOnQuit(u.version))
                        : null,
                    enabled: !busy,
                    onTap: up.install,
                  ),
                if (isDesktop)
                  ListTile(
                    leading: const Icon(Icons.folder_open),
                    title: Text(l10n.updateShowFolder),
                    onTap: up.showFolder,
                  ),
              ],
            ],
            // Every platform: the newest release's page (its notes and all files).
            ListTile(
              key: const Key('update.page'),
              leading: const Icon(Icons.open_in_new),
              title: Text(l10n.updatePage),
              onTap: () => openOrShow(context, releasePage()),
            ),
          ],
        );
      },
    );
  }
}

/// Opens [url]; where nothing can open it (a TV without a browser) the address shows in a dialog instead.
Future<void> openOrShow(BuildContext context, String url) async {
  if (await PlatformBridge.openUrl(url) || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: SelectableText(url),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}
