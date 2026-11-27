// Settings → Account → Web player (with a paired gerdTV host; gerdtv-host serves the page): a one-time login link
// for any browser (QR and copy; it works once, for 10 minutes), and the open web sessions with End. The requests are
// sealed with the pairing key and go to the host's front door (core: pairing.rs app_request), so this works away
// from home too.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/pairing.dart';
import '../theme.dart';
import 'devices_screen.dart';

class WebPlayerScreen extends StatefulWidget {
  const WebPlayerScreen({super.key, required this.session, required this.host});
  final Session session;

  /// The paired host (its `web` is the front door).
  final PeerInfo host;

  @override
  State<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

class _WebPlayerScreenState extends State<WebPlayerScreen> {
  String? _link;
  List<WebSessionInfo>? _sessions;
  String? _error;
  bool _busy = false;

  String get _me => widget.session.devices.me.id;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSessions());
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _makeLink() => _run(() async {
    _link = await hostLink(meId: _me, peer: widget.host);
  });

  Future<void> _loadSessions() => _run(() async {
    _sessions = await hostSessions(meId: _me, peer: widget.host);
  });

  Future<void> _end(WebSessionInfo s) => _run(() async {
    await hostEndSession(meId: _me, peer: widget.host, id: s.id);
    _sessions = await hostSessions(meId: _me, peer: widget.host);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    String time(int unix) {
      final t = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.webTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Tokens.space * 2),
        children: [
          Text(widget.host.web, style: theme.textTheme.bodySmall),
          const SizedBox(height: Tokens.space * 2),
          FilledButton(
            key: const Key('web.makeLink'),
            onPressed: _busy ? null : _makeLink,
            child: Text(l10n.webMakeLink),
          ),
          const SizedBox(height: Tokens.space),
          Text(l10n.webLinkHint),
          if (_link != null) ...[
            const SizedBox(height: Tokens.space * 2),
            Align(
              alignment: Alignment.centerLeft,
              child: QrView(text: _link!, size: 220),
            ),
            const SizedBox(height: Tokens.space),
            Row(
              children: [
                Expanded(
                  child: SelectableText(_link!, key: const Key('web.link')),
                ),
                IconButton(
                  tooltip: l10n.webCopy,
                  icon: const Icon(Icons.copy),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _link!)),
                ),
              ],
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Tokens.space),
              child: Text(
                l10n.devicesFailed(_error!),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: Tokens.space * 3),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.webSessions,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: l10n.devicesSearch,
                icon: const Icon(Icons.refresh),
                onPressed: _busy ? null : _loadSessions,
              ),
            ],
          ),
          if (_sessions != null && _sessions!.isEmpty) Text(l10n.webNoSessions),
          for (final s in _sessions ?? const <WebSessionInfo>[])
            ListTile(
              key: Key('web.session.${s.id}'),
              leading: const Icon(Icons.public),
              title: Text(s.agent.isEmpty ? '?' : s.agent, maxLines: 2),
              subtitle: Text(l10n.webUntil(time(s.expires))),
              trailing: TextButton(
                onPressed: _busy ? null : () => _end(s),
                child: Text(l10n.webEnd),
              ),
            ),
        ],
      ),
    );
  }
}
