// Settings → Account → Trakt / Simkl: link the profile with a device code (link_dialog.dart), or unlink. Trakt
// first asks for the user's own Trakt app (its client id and secret: no secret ships with gerdTV), Simkl uses
// gerdTV's client id from the build; a build without it says so.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../services/tracking.dart';
import '../src/rust/api/tracking.dart';
import '../theme.dart';
import 'link_dialog.dart';

class TrackSettings extends StatefulWidget {
  const TrackSettings({
    super.key,
    required this.session,
    required this.service,
  });
  final Session session;
  final TrackService service;

  @override
  State<TrackSettings> createState() => _TrackSettingsState();
}

class _TrackSettingsState extends State<TrackSettings> {
  String? _error;
  bool _busy = false;
  final _id = TextEditingController();
  final _secret = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    final s = widget.service;
    final tracking = widget.session.tracking;
    final needsApp = AppLocalizations.of(context).trackClientId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (s.ownApp && _id.text.trim().isNotEmpty) {
        await tracking.setApp(s, (_id.text, _secret.text));
      }
      final c = tracking.client(s);
      if (c == null) throw needsApp;
      final code = await trackDeviceStart(
        service: s.id,
        clientId: c.$1,
        clientSecret: c.$2,
      );
      if (!mounted) return;
      final token = await deviceCodeLogin(
        context,
        title: s.label,
        userCode: code.userCode,
        uri: code.verificationUri,
        interval: code.interval,
        expiresIn: code.expiresIn,
        poll: () async {
          final p = await trackDevicePoll(
            service: s.id,
            clientId: c.$1,
            clientSecret: c.$2,
            deviceCode: code.deviceCode,
          );
          return (token: p.token, failed: p.failed, slowDown: p.slowDown);
        },
      );
      if (token != null) await widget.session.tracking.link(s, token);
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.service;
    final tracking = widget.session.tracking;
    if (tracking.linked(s)) {
      return ListTile(
        key: Key('track.${s.id}.linked'),
        leading: const Icon(Icons.check_circle_outline),
        title: Text(l10n.trackLinked(s.label)),
        subtitle: Text(l10n.trackHint),
        trailing: TextButton(
          key: Key('track.${s.id}.unlink'),
          onPressed: () async {
            await tracking.link(s, null);
            await tracking.setApp(s, null);
            setState(() {});
          },
          child: Text(l10n.premiumizeUnlink),
        ),
      );
    }
    final link = ListTile(
      key: Key('track.${s.id}.link'),
      leading: const Icon(Icons.link),
      title: Text(l10n.trackLink(s.label)),
      subtitle: Text(
        _error ??
            (s.ownApp || s.clientId.isNotEmpty
                ? l10n.trackHint
                : l10n.trackUnavailable),
      ),
      enabled: (s.ownApp || s.clientId.isNotEmpty) && !_busy,
      onTap: _link,
    );
    if (!s.ownApp) return link;
    // Trakt: the user's own app (trakt.tv → Settings → Your API Apps → New Application).
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
          child: Column(
            children: [
              Text(l10n.trackOwnAppHint),
              TextField(
                key: Key('track.${s.id}.clientId'),
                controller: _id,
                decoration: InputDecoration(labelText: l10n.trackClientId),
              ),
              TextField(
                key: Key('track.${s.id}.clientSecret'),
                controller: _secret,
                obscureText: true,
                decoration: InputDecoration(labelText: l10n.trackClientSecret),
              ),
            ],
          ),
        ),
        link,
      ],
    );
  }
}
