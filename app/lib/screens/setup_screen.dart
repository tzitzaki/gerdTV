// First run: the provider's login (Xtream Codes) or a playlist URL (M3U), nothing else. Connecting runs the first
// sync; a refused login or an unreachable server is shown under the button and the form stays filled.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import 'app_logo.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.session});
  final Session session;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

/// Field validation, kept free of widgets so it is unit-testable.
String? checkUrl(String? v, AppLocalizations l10n) {
  final s = v?.trim() ?? '';
  if (s.isEmpty) return l10n.setupRequired;
  final u = Uri.tryParse(s);
  if (u == null ||
      !(u.scheme == 'http' || u.scheme == 'https') ||
      u.host.isEmpty) {
    return l10n.setupBadUrl;
  }
  return null;
}

class _SetupScreenState extends State<SetupScreen> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _m3u = TextEditingController();
  bool _xtream = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_server, _user, _pass, _m3u]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final server = _server.text.trim();
    final info = ProfileInfo(
      id: '',
      name: _xtream ? (Uri.tryParse(server)?.host ?? 'Xtream Codes') : 'M3U',
      source: _xtream ? SourceKind.xtream : SourceKind.m3UUrl,
      server: _xtream ? server : '',
      userAgent: '',
    );
    final secrets = _xtream
        ? [_user.text.trim(), _pass.text]
        : [_m3u.text.trim()];
    final error = await widget.session.addProfile(info, secrets);
    if (!mounted) return;
    // Added from Settings (a pushed page): back to the app, now on the new profile.
    if (error == null && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String? required(String? v) =>
        (v == null || v.trim().isEmpty) ? l10n.setupRequired : null;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Tokens.space * 3),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: AppLogoMark(logo: widget.session.logo, size: 64),
                    ),
                    const SizedBox(height: Tokens.space * 2),
                    Text(
                      l10n.setupTitle,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: Tokens.space),
                    Text(l10n.setupIntro),
                    const SizedBox(height: Tokens.space * 3),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(l10n.setupXtream),
                        ),
                        ButtonSegment(value: false, label: Text(l10n.setupM3u)),
                      ],
                      selected: {_xtream},
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() => _xtream = s.first),
                    ),
                    const SizedBox(height: Tokens.space * 3),
                    if (_xtream) ...[
                      TextFormField(
                        key: const Key('setup.server'),
                        controller: _server,
                        decoration: InputDecoration(
                          labelText: l10n.setupServer,
                          hintText: 'http://example.com:8080',
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        validator: (v) => checkUrl(v, l10n),
                      ),
                      const SizedBox(height: Tokens.space * 2),
                      TextFormField(
                        key: const Key('setup.username'),
                        controller: _user,
                        decoration: InputDecoration(
                          labelText: l10n.setupUsername,
                        ),
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        validator: required,
                      ),
                      const SizedBox(height: Tokens.space * 2),
                      TextFormField(
                        key: const Key('setup.password'),
                        controller: _pass,
                        decoration: InputDecoration(
                          labelText: l10n.setupPassword,
                        ),
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        validator: required,
                        onFieldSubmitted: (_) => _connect(),
                      ),
                    ] else
                      TextFormField(
                        key: const Key('setup.m3u'),
                        controller: _m3u,
                        decoration: InputDecoration(
                          labelText: l10n.setupM3uUrl,
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        validator: (v) => checkUrl(v, l10n),
                        onFieldSubmitted: (_) => _connect(),
                      ),
                    const SizedBox(height: Tokens.space * 3),
                    FilledButton(
                      key: const Key('setup.connect'),
                      onPressed: _busy ? null : _connect,
                      child: Padding(
                        padding: const EdgeInsets.all(Tokens.space * 1.5),
                        child: Text(
                          _busy ? l10n.setupConnecting : l10n.setupConnect,
                        ),
                      ),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: Tokens.space * 2),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Tokens.space * 2),
                        child: Text(
                          l10n.setupFailed(_error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
