// The update bar under the app (owner decision: gerdTV tells about a new version by itself): "Version X is available"
// with the one step this platform can take (services/updater.dart has the flow): macOS Install and restart (without
// it, the update goes in when gerdTV quits), Android Install (the system's installer), Linux Show in folder, iPhone
// and iPad the IPA itself. Until the file is fetched the button fetches it first. The close button hides the bar for
// this version; a newer one shows it again. Sits below the navigator like the now-playing bar, so every page keeps it.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../services/updater.dart';
import '../theme.dart';
import 'update_settings.dart' show openOrShow;

class UpdateBar extends StatelessWidget {
  const UpdateBar({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final u = session.updater;
    return ListenableBuilder(
      listenable: Listenable.merge([u.available, u.file, u.busy, u.dismissed]),
      builder: (context, _) {
        final update = u.available.value;
        if (update == null || u.dismissed.value == update.version) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final scheme = Theme.of(context).colorScheme;
        final file = u.file.value;
        final (String label, VoidCallback action) = switch (updatePlatform) {
          'ios' => (l10n.updateIpa, () => openOrShow(context, update.url)),
          _ when file == null => (l10n.updateDownload, u.auto),
          'macos' => (l10n.updateInstallRestart, u.install),
          'android' => (l10n.updateInstall, u.install),
          _ => (l10n.updateShowFolder, u.showFolder),
        };
        return Material(
          key: const Key('update.bar'),
          color: scheme.primaryContainer,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Tokens.space * 2,
                vertical: Tokens.space,
              ),
              child: Row(
                children: [
                  Icon(Icons.system_update, color: scheme.onPrimaryContainer),
                  const SizedBox(width: Tokens.space * 1.5),
                  Expanded(
                    child: Text(
                      // macOS with the file armed: it goes in at the next quit even without a tap.
                      Platform.isMacOS && file != null
                          ? l10n.updateOnQuit(update.version)
                          : l10n.updateAvailable(update.version),
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ),
                  TextButton(
                    key: const Key('update.bar.action'),
                    onPressed: u.busy.value ? null : action,
                    child: Text(label),
                  ),
                  IconButton(
                    key: const Key('update.bar.close'),
                    tooltip: l10n.close,
                    icon: const Icon(Icons.close),
                    onPressed: () => u.dismissed.value = update.version,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
