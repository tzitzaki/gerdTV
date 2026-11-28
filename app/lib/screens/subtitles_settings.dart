// Settings → Services → OpenSubtitles: the user's own API key, and optionally the account's login, whose download
// quota then applies (without one a free key allows 5 a day). The login is checked with OpenSubtitles when saved.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../theme.dart';

class SubtitlesSettings extends StatefulWidget {
  const SubtitlesSettings({super.key, required this.session});
  final Session session;

  @override
  State<SubtitlesSettings> createState() => _SubtitlesSettingsState();
}

class _SubtitlesSettingsState extends State<SubtitlesSettings> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login(String? user) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.setSubtitlesLogin(user, _password.text);
      _password.clear();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.space * 2,
        vertical: Tokens.space,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: const Key('settings.subtitlesKey'),
            initialValue: s.subtitlesKey ?? '',
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.subtitlesKey,
              helperText: l10n.subtitlesKeyHint,
              helperMaxLines: 4,
            ),
            onFieldSubmitted: (v) async {
              await s.setSubtitlesKey(v);
              setState(() {});
            },
          ),
          if (s.subtitlesKey != null && s.hasSubtitlesLogin)
            ListTile(
              key: const Key('settings.subtitlesLoggedIn'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.subtitlesLoggedIn),
              trailing: TextButton(
                onPressed: _busy ? null : () => _login(null),
                child: Text(l10n.premiumizeUnlink),
              ),
            )
          else if (s.subtitlesKey != null) ...[
            TextField(
              key: const Key('settings.subtitlesUser'),
              controller: _user,
              autocorrect: false,
              decoration: InputDecoration(labelText: l10n.setupUsername),
            ),
            TextField(
              key: const Key('settings.subtitlesPassword'),
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.setupPassword,
                helperText: _error ?? l10n.subtitlesLoginHint,
                helperMaxLines: 3,
              ),
              onSubmitted: (_) => _login(_user.text),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Tokens.space),
              child: FilledButton(
                key: const Key('settings.subtitlesLogin'),
                onPressed: _busy ? null : () => _login(_user.text),
                child: Text(l10n.subtitlesLogin),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
