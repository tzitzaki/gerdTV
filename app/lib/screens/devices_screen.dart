// Settings → Account → Devices & sync, and the first run's welcome screen (services/devices.dart has the
// mechanism). Three parts:
// - Show a code: this device listens; its QR (for a phone's camera) and the code to type elsewhere.
// - Pair with a device on this network: on the Mac also by scanning its QR with the webcam; the devices mDNS finds; pick one, type the code it shows, then the found
//   device's name and platform are shown and nothing is sent before Sync is pressed ("pair as you scan").
// - Paired devices: Sync now (two-way) and Forget.
// No dialog except Forget's confirmation (the design's one modal); the camera's link opens [PairLinkScreen], the same
// confirmation as a page. The code part ([PairCodeView]) and the nearby part ([NearbyDevices]) are shared with the
// first run's welcome screen (welcome_screen.dart), so both pair the same way.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform/platform_bridge.dart';
import '../services/session.dart';
import '../src/rust/api/pairing.dart';
import '../theme.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.session});
  final Session session;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String? _qr;
  String? _status;

  @override
  void initState() {
    super.initState();
    final d = widget.session.devices;
    d.applied.addListener(_onApplied);
    d.failed.addListener(_onFailed);
  }

  @override
  void dispose() {
    final d = widget.session.devices;
    d.applied.removeListener(_onApplied);
    d.failed.removeListener(_onFailed);
    if (_qr != null) d.stopPairing();
    super.dispose();
  }

  void _onApplied() {
    final a = widget.session.devices.applied.value;
    if (a == null || !mounted) return;
    setState(
      () => _status = AppLocalizations.of(context).devicesSynced(a.peer.name),
    );
  }

  void _onFailed() {
    final f = widget.session.devices.failed.value;
    if (f == null || !mounted) return;
    setState(() => _status = AppLocalizations.of(context).devicesFailed(f));
  }

  Future<void> _showCode() async {
    final qr = await widget.session.devices.startPairing();
    if (mounted) setState(() => _qr = qr);
  }

  Future<void> _syncNow(PeerInfo p) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _status = l10n.devicesSyncing);
    try {
      final a = await widget.session.devices.syncNow(p);
      if (mounted) setState(() => _status = l10n.devicesSynced(a.peer.name));
    } catch (e) {
      if (mounted) setState(() => _status = l10n.devicesFailed('$e'));
    }
  }

  Future<void> _forget(PeerInfo p) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.devicesForgetConfirm(p.device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.devicesForget),
          ),
        ],
      ),
    );
    if (ok == true) await widget.session.devices.forget(p);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final d = widget.session.devices;
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.space * 2,
        Tokens.space * 3,
        Tokens.space * 2,
        Tokens.space,
      ),
      child: Text(text, style: theme.textTheme.titleMedium),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.devicesTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Tokens.space * 4),
        children: [
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(Tokens.space * 2),
              child: Text(
                _status!,
                key: const Key('devices.status'),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          // This device receives: QR and code.
          heading(l10n.devicesShowCode),
          if (_qr == null)
            ListTile(
              key: const Key('devices.showCode'),
              leading: const Icon(Icons.qr_code_2),
              title: Text(l10n.devicesShowCode),
              subtitle: Text(l10n.devicesShowCodeHint),
              onTap: _showCode,
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PairCodeView(session: widget.session, qr: _qr!),
                  const SizedBox(height: Tokens.space),
                  Text(l10n.devicesShowCodeHint),
                ],
              ),
            ),
          // This device connects to one it finds.
          heading(l10n.devicesNearby),
          NearbyDevices(
            session: widget.session,
            onStatus: (m) => setState(() => _status = m),
          ),
          // Remembered devices.
          ValueListenableBuilder<List<PeerInfo>>(
            valueListenable: d.peers,
            builder: (context, peers, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (peers.isNotEmpty) heading(l10n.devicesPaired),
                for (final p in peers)
                  ListTile(
                    key: Key('devices.peer.${p.device.id}'),
                    leading: const Icon(Icons.sync),
                    title: Text(p.device.name),
                    subtitle: Text(p.device.platform),
                    onTap: () => _syncNow(p),
                    trailing: IconButton(
                      tooltip: l10n.devicesForget,
                      icon: const Icon(Icons.link_off),
                      onPressed: () => _forget(p),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The other device answered: who it is, and nothing sent before Sync. Also the page the camera's link opens.
class PairConfirmScreen extends StatefulWidget {
  const PairConfirmScreen({
    super.key,
    required this.session,
    required this.connection,
    required this.addr,
  });
  final Session session;
  final PairConnection connection;
  final String addr;

  @override
  State<PairConfirmScreen> createState() => _PairConfirmScreenState();
}

class _PairConfirmScreenState extends State<PairConfirmScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.devices.exchange(
        widget.connection,
        addr: widget.addr,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final peer = widget.connection.peer();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.devicesTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(Tokens.space * 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.devicesConfirm(peer.name, peer.platform),
                  key: const Key('devices.confirm'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: Tokens.space * 2),
                Text(l10n.devicesConfirmBody),
                const SizedBox(height: Tokens.space * 3),
                FilledButton(
                  key: const Key('devices.sync'),
                  onPressed: _busy ? null : _sync,
                  child: Text(l10n.devicesSync),
                ),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    l10n.devicesFailed(_error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// This device's pairing code while it listens ([Devices.startPairing] gave [qr]): the QR for a phone's camera, the
/// code to type on the other device, and this device's name. A new code (the old one was used) changes the QR too.
class PairCodeView extends StatelessWidget {
  const PairCodeView({super.key, required this.session, required this.qr});
  final Session session;
  final String qr;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final d = session.devices;
    final theme = Theme.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: d.code,
      builder: (context, code, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          QrView(text: d.qrText() ?? qr, size: 220),
          const SizedBox(height: Tokens.space * 2),
          SelectableText(
            code ?? '',
            key: const Key('devices.code'),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              letterSpacing: 2,
            ),
          ),
          Text('${d.me.name} · ${l10n.devicesWaiting}'),
        ],
      ),
    );
  }
}

/// The gerdTV devices this one finds on the network (searched on open), the Mac's webcam scan, and for a picked
/// device its code field; Next connects and opens [PairConfirmScreen], which shows who answered before anything is
/// sent. Errors go to [onStatus] (the page shows them on top).
class NearbyDevices extends StatefulWidget {
  const NearbyDevices({
    super.key,
    required this.session,
    required this.onStatus,
  });
  final Session session;
  final ValueChanged<String?> onStatus;

  @override
  State<NearbyDevices> createState() => _NearbyDevicesState();
}

class _NearbyDevicesState extends State<NearbyDevices> {
  List<FoundDevice>? _found;
  bool _searching = false;

  /// The device picked from the list, waiting for its code.
  FoundDevice? _picked;
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await widget.session.devices.discover().catchError(
      (_) => <FoundDevice>[],
    );
    if (mounted) {
      setState(() {
        _found = found;
        _searching = false;
      });
    }
  }

  Future<void> _connect() async {
    final picked = _picked!;
    final l10n = AppLocalizations.of(context);
    widget.onStatus(null);
    try {
      final c = await widget.session.devices.connectCode(
        picked.addr,
        _code.text,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PairConfirmScreen(
            session: widget.session,
            connection: c,
            addr: picked.addr,
          ),
        ),
      );
      if (mounted) {
        setState(() {
          _picked = null;
          _code.clear();
        });
      }
    } catch (e) {
      if (mounted) widget.onStatus(l10n.devicesFailed('$e'));
    }
  }

  /// The webcam's QR: a pairing link opens its confirmation (as the system camera's link does); anything else says so.
  Future<void> _scan(AppLocalizations l10n) async {
    final text = await PlatformBridge.scanQr(l10n.devicesScanCamera);
    if (text == null || !mounted) return; // closed, or no camera
    if (!widget.session.devices.openLink(text)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.devicesScanNotCode)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The Mac has no system camera that opens links: its webcam scans the other device's QR here.
        if (PlatformBridge.canScanQr)
          ListTile(
            key: const Key('devices.scan'),
            leading: const Icon(Icons.qr_code_scanner),
            title: Text(l10n.devicesScanCamera),
            onTap: () => _scan(l10n),
          ),
        if (_searching) const LinearProgressIndicator(),
        for (final f in _found ?? const <FoundDevice>[])
          ListTile(
            key: Key('devices.found.${f.device.id}'),
            leading: const Icon(Icons.devices_other),
            title: Text(f.device.name),
            subtitle: Text(f.device.platform),
            selected: _picked?.device.id == f.device.id,
            onTap: () => setState(() => _picked = f),
          ),
        if (_found != null && _found!.isEmpty && !_searching)
          ListTile(title: Text(l10n.devicesNoneFound)),
        if (_picked != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tokens.space * 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('devices.codeField'),
                    controller: _code,
                    autofocus: true,
                    autocorrect: false,
                    // Six digits: the number pad (a TV remote's too).
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.devicesEnterCode(_picked!.device.name),
                    ),
                    onSubmitted: (_) => _connect(),
                  ),
                ),
                const SizedBox(width: Tokens.space),
                FilledButton(
                  key: const Key('devices.connect'),
                  onPressed: _connect,
                  child: Text(l10n.devicesNext),
                ),
              ],
            ),
          ),
        ListTile(
          key: const Key('devices.search'),
          leading: const Icon(Icons.refresh),
          title: Text(l10n.devicesSearch),
          subtitle: Text(l10n.devicesScanHint),
          enabled: !_searching,
          onTap: _search,
        ),
      ],
    );
  }
}

/// The camera's pairing link: connects (the code is in the link) and asks before sending.
Future<void> openPairLink(Session session, PairLink link) async {
  final nav = session.navigatorKey.currentState;
  if (nav == null) return;
  try {
    final c = await session.devices.connectCode(link.addr, link.code);
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PairConfirmScreen(session: session, connection: c, addr: link.addr),
      ),
    );
  } catch (e) {
    session.devices.failed.value = '$e';
  }
}

/// A QR code, black modules on white with the standard quiet zone (4 modules), drawn from the core's matrix.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.text, required this.size});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qr = pairQr(text: text);
    return Semantics(
      label: 'QR',
      child: CustomPaint(
        key: const Key('devices.qr'),
        size: Size.square(size),
        painter: _QrPainter(qr),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr);
  final QrInfo qr;

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 4;
    final n = qr.width + quiet * 2;
    final cell = size.width / n;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFF000000);
    for (var y = 0; y < qr.width; y++) {
      for (var x = 0; x < qr.width; x++) {
        if (qr.modules[y * qr.width + x]) {
          canvas.drawRect(
            Rect.fromLTWH((x + quiet) * cell, (y + quiet) * cell, cell, cell),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.qr.modules != qr.modules;
}
