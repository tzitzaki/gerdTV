// The device-code login every linked service uses (Premiumize, Trakt, Simkl): a dialog shows the code and the
// address to type it at on another device, and polls the service until it says yes. Closing the dialog cancels.
// Debugging: a code that never gets accepted usually means the wrong client id in the build (the service answers
// invalid_client, shown as the error); a slow_down answer adds 5 s between polls, as OAuth's device flow asks.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme.dart';
import 'update_settings.dart' show openOrShow;

/// One poll's answer: the token once confirmed, the reason when it stopped, or neither (ask again).
typedef LinkPoll = ({String? token, String? failed, bool slowDown});

/// Shows [userCode] and [uri] and polls every [interval] seconds for up to [expiresIn]; the token, or null when the
/// user closed the dialog or the code ran out. A refused code throws its reason.
Future<String?> deviceCodeLogin(
  BuildContext context, {
  required String title,
  required String userCode,
  required String uri,
  required int interval,
  required int expiresIn,
  required Future<LinkPoll> Function() poll,
}) async {
  var open = true;
  final l10n = AppLocalizations.of(context);
  final dialog = showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.linkCodeHint),
          const SizedBox(height: Tokens.space),
          SelectableText(
            userCode,
            key: const Key('link.code'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          TextButton(
            onPressed: () => openOrShow(context, uri),
            child: Text(uri),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('link.close'),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    ),
  ).whenComplete(() => open = false);
  var wait = Duration(seconds: interval);
  final end = DateTime.now().add(Duration(seconds: expiresIn));
  try {
    while (open && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(wait);
      if (!open) return null;
      final p = await poll();
      if (p.token != null) return p.token;
      if (p.failed != null) throw p.failed!;
      if (p.slowDown) wait += const Duration(seconds: 5);
    }
    return null;
  } finally {
    if (open && context.mounted) Navigator.of(context).pop();
    await dialog;
  }
}
