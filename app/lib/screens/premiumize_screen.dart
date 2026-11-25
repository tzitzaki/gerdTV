// Premiumize (owner request: a debrid account): linked per profile in Settings → Account, then the cloud shows as a
// row atop Movies: its folders and files, playable files play like a recording, and the transfers with their
// progress (a finished one opens its folder). The core talks to Premiumize (gerdtv_core::premiumize); the token is
// in the secure storage (Session.linkPremiumize).
// Linking: the account's API key (premiumize.me/account) works for everyone; the code login (premiumize.me/device)
// shows only when the build has gerdTV's registered client id (--dart-define=GERDTV_PREMIUMIZE_CLIENT_ID=…, a
// public identifier from a repository variable; no secret ships in the app).
// Debugging: "authentication_failed" in an error line means Premiumize no longer accepts the key or token: link it
// again.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/premiumize.dart';
import '../theme.dart';
import 'player_screen.dart';
import 'link_dialog.dart';

/// gerdTV's client id at Premiumize, given to release builds; empty: only the API key links.
const premiumizeClientId = String.fromEnvironment(
  'GERDTV_PREMIUMIZE_CLIENT_ID',
);

/// "1.4 GB", "820 MB" (metric, as the rest of the app).
String sizeLabel(int bytes) => bytes >= 1000000000
    ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
    : '${(bytes / 1e6).round()} MB';

/// One folder of the cloud ([folderId] null: the root, with Transfers in its bar).
class PremiumizeScreen extends StatefulWidget {
  const PremiumizeScreen({
    super.key,
    required this.session,
    this.folderId,
    this.title,
  });
  final Session session;
  final String? folderId;
  final String? title;

  @override
  State<PremiumizeScreen> createState() => _PremiumizeScreenState();
}

class _PremiumizeScreenState extends State<PremiumizeScreen> {
  Session get session => widget.session;

  /// Asked once: as a section this rebuilds with the shell (a sync's progress, say).
  late final _entries = pmFolder(
    token: session.premiumizeToken ?? '',
    id: widget.folderId,
  );

  Future<void> _play(BuildContext context, PmEntry e) async {
    final item = ItemInfo(
      key: 'premiumize:${e.id}',
      kind: ItemKind.movie,
      name: e.name,
      category: '',
      logo: '',
      archiveDays: 0,
      group: '',
    );
    // Started here (the URL isn't the library's), then the player shows the running stream.
    unawaited(session.playUrl(item, e.link));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(session: session, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? l10n.premiumizeCloud),
        actions: [
          if (widget.folderId == null)
            TextButton.icon(
              key: const Key('premiumize.transfers'),
              icon: const Icon(Icons.downloading),
              label: Text(l10n.premiumizeTransfers),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _TransfersScreen(session: session),
                ),
              ),
            ),
        ],
      ),
      body: FutureBuilder<List<PmEntry>>(
        future: _entries,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text(l10n.syncFailed('${snap.error}')));
          }
          final entries = snap.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) {
            return Center(child: Text(l10n.premiumizeEmpty));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return ListTile(
                key: Key('premiumize.entry.${e.id}'),
                leading: Icon(
                  e.folder
                      ? Icons.folder_outlined
                      : e.playable
                      ? Icons.movie_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(e.name, maxLines: 2),
                subtitle: e.folder ? null : Text(sizeLabel(e.size.toInt())),
                enabled: e.folder || e.playable,
                onTap: e.folder
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PremiumizeScreen(
                            session: session,
                            folderId: e.id,
                            title: e.name,
                          ),
                        ),
                      )
                    : e.playable
                    ? () => _play(context, e)
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}

/// The transfers, newest first, with their progress; a finished one opens where it landed.
class _TransfersScreen extends StatelessWidget {
  const _TransfersScreen({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.premiumizeTransfers)),
      body: FutureBuilder<List<PmTransfer>>(
        future: pmTransfers(token: session.premiumizeToken ?? ''),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text(l10n.syncFailed('${snap.error}')));
          }
          final list = snap.data;
          if (list == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (list.isEmpty) return Center(child: Text(l10n.premiumizeEmpty));
          return ListView(
            children: [
              for (final t in list)
                ListTile(
                  title: Text(t.name, maxLines: 2),
                  subtitle: t.status == 'running' || t.status == 'queued'
                      ? LinearProgressIndicator(value: t.progress)
                      : Text(t.message.isEmpty ? t.status : t.message),
                  trailing: t.folderId.isEmpty
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: t.folderId.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PremiumizeScreen(
                              session: session,
                              folderId: t.folderId,
                              title: t.name,
                            ),
                          ),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Settings → Account → Premiumize: link with the API key (or a code, where the build can), or unlink.
class PremiumizeSettings extends StatefulWidget {
  const PremiumizeSettings({super.key, required this.session});
  final Session session;

  @override
  State<PremiumizeSettings> createState() => _PremiumizeSettingsState();
}

class _PremiumizeSettingsState extends State<PremiumizeSettings> {
  final _key = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _link(Future<String?> Function() token) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = await token();
      if (t != null) await widget.session.linkPremiumize(t);
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    if (s.premiumizeToken != null) {
      return ListTile(
        key: const Key('premiumize.linked'),
        leading: const Icon(Icons.cloud_done_outlined),
        title: Text(l10n.premiumizeLinked),
        trailing: TextButton(
          key: const Key('premiumize.unlink'),
          onPressed: () async {
            await s.linkPremiumize(null);
            setState(() {});
          },
          child: Text(l10n.premiumizeUnlink),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('premiumize.key'),
            controller: _key,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.premiumizeKey,
              helperText: l10n.premiumizeKeyHint,
              errorText: _error,
            ),
            onSubmitted: (_) => _link(() async => _key.text),
          ),
          const SizedBox(height: Tokens.space),
          Wrap(
            spacing: Tokens.space,
            children: [
              FilledButton(
                key: const Key('premiumize.link'),
                onPressed: _busy ? null : () => _link(() async => _key.text),
                child: Text(l10n.premiumizeLink),
              ),
              if (premiumizeClientId.isNotEmpty)
                OutlinedButton(
                  key: const Key('premiumize.code'),
                  onPressed: _busy
                      ? null
                      : () => _link(() => _deviceLogin(context)),
                  child: Text(l10n.premiumizeCode),
                ),
            ],
          ),
          const SizedBox(height: Tokens.space),
        ],
      ),
    );
  }
}

/// The code login at premiumize.me/device (link_dialog.dart).
Future<String?> _deviceLogin(BuildContext context) async {
  final code = await pmDeviceStart(clientId: premiumizeClientId);
  if (!context.mounted) return null;
  return deviceCodeLogin(
    context,
    title: AppLocalizations.of(context).premiumizeCode,
    userCode: code.userCode,
    uri: code.verificationUri,
    interval: code.interval,
    expiresIn: code.expiresIn,
    poll: () async {
      final p = await pmDevicePoll(
        clientId: premiumizeClientId,
        deviceCode: code.deviceCode,
      );
      return (token: p.token, failed: p.failed, slowDown: p.slowDown);
    },
  );
}
