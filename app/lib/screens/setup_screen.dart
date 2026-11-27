// First run: the provider's login (Xtream Codes) or a playlist URL (M3U), nothing else. Connecting runs the first
// sync; a refused login or an unreachable server is shown under the button and the form stays filled.
// With [SetupScreen.edit] the same form edits the open profile's provider (Settings → Account): pre-filled, with a
// name field, and Save replaces the login only once the new one works (Session.updateProfile).

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import 'app_logo.dart';
import 'devices_screen.dart';
import '../src/rust/api/library.dart';
import '../theme.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.session, this.edit});
  final Session session;

  /// The profile to edit; null adds a new one.
  final ProfileInfo? edit;

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
  final _userAgent = TextEditingController();
  final _name = TextEditingController();
  bool _xtream = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.edit;
    if (p == null) return;
    // A profile without a provider (setup skipped) gets its name from the provider it gets now.
    if (p.source != SourceKind.none) _name.text = p.name;
    _xtream = p.source != SourceKind.m3UUrl;
    _server.text = p.server;
    _userAgent.text = p.userAgent;
    // The login itself is only in secure storage; it fills in a moment later.
    widget.session.secrets.read(p.id).then((s) {
      if (!mounted || s == null) return;
      if (_xtream && s.length >= 2) {
        _user.text = s[0];
        _pass.text = s[1];
      } else if (!_xtream && s.isNotEmpty) {
        _m3u.text = s[0];
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_server, _user, _pass, _m3u, _userAgent, _name]) {
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
    final edit = widget.edit;
    final name = _name.text.trim();
    final info = ProfileInfo(
      id: edit?.id ?? '',
      name: name.isNotEmpty
          ? name
          : _xtream
          ? (Uri.tryParse(server)?.host ?? 'Xtream Codes')
          : 'M3U',
      source: _xtream ? SourceKind.xtream : SourceKind.m3UUrl,
      server: _xtream ? server : '',
      userAgent: _userAgent.text,
      maxConnections: edit?.maxConnections,
    );
    final secrets = _xtream
        ? [_user.text.trim(), _pass.text]
        : [_m3u.text.trim()];
    final error = edit == null
        ? await widget.session.addProfile(info, secrets)
        : await widget.session.updateProfile(info, secrets);
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
    // Opened from Settings (add or edit): a back arrow, since desktop has no swipe-back; not while a login is being
    // tested (PopScope also holds Esc and the system back then). The first run has nothing to go back to.
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: Navigator.of(context).canPop() ? AppBar() : null,
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
                        widget.edit == null ||
                                widget.edit!.source == SourceKind.none
                            ? l10n.setupTitle
                            : l10n.setupEditTitle,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: Tokens.space),
                      Text(l10n.setupIntro),
                      const SizedBox(height: Tokens.space * 3),
                      if (widget.edit != null) ...[
                        TextFormField(
                          key: const Key('setup.name'),
                          controller: _name,
                          decoration: InputDecoration(
                            labelText: l10n.setupName,
                          ),
                        ),
                        const SizedBox(height: Tokens.space * 3),
                      ],
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(
                            value: true,
                            label: Text(l10n.setupXtream),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text(l10n.setupM3u),
                          ),
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
                            _busy
                                ? l10n.setupConnecting
                                : widget.edit == null
                                ? l10n.setupConnect
                                : l10n.setupSave,
                          ),
                        ),
                      ),
                      // First run only (not when added from Settings): from another device, or Settings without a provider.
                      if (widget.edit == null &&
                          !Navigator.of(context).canPop())
                        TextButton(
                          key: const Key('setup.fromDevice'),
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        DevicesScreen(session: widget.session),
                                  ),
                                ),
                          child: Text(l10n.setupFromDevice),
                        ),
                      if (widget.edit == null &&
                          !Navigator.of(context).canPop())
                        TextButton(
                          key: const Key('setup.skip'),
                          onPressed: _busy
                              ? null
                              : () => widget.session.skipSetup(
                                  l10n.setupNoProvider,
                                ),
                          child: Text(l10n.setupSkip),
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
                      const SizedBox(height: Tokens.space * 3),
                      // Optional (some providers only answer players they know), so below Connect, which must stay in view.
                      TextFormField(
                        key: const Key('setup.userAgent'),
                        controller: _userAgent,
                        decoration: InputDecoration(
                          labelText: l10n.userAgent,
                          helperText: l10n.setupUserAgentHint,
                          helperMaxLines: 2,
                        ),
                        autocorrect: false,
                        onFieldSubmitted: (_) => _connect(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
