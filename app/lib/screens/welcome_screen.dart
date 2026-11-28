// First run: bring the provider over from a device that already has gerdTV, nothing to type (owner decision: no
// provider form, and a calm screen: one instruction, the QR, Skip). This device listens at once and shows its QR and
// code (PairCodeView, the Devices & sync page's own widget, devices_screen.dart). A finished sync opens the provider
// that came (Session's apply path), which replaces this screen with the app. Skip to the app opens gerdTV without a
// provider (Session.skipSetup); the login is then added in Settings → Account. Two quiet extras: "Get gerdTV for your
// phone" unfolds this version's phone files as QRs (not on phones), and the devices found nearby (NearbyDevices) stay
// faded until the remote or the pointer reaches them.
// Remote: Skip takes the focus first; Up/Down walk the page (fieldDpadKeys in theme.dart), the scroll view follows.
// Debugging: no QR means Devices.startPairing failed or no local IP was found (pairLocalIp); the status line shows a
// failed sync's reason.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../src/rust/api/update.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'devices_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.session});
  final Session session;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  String? _qr;
  String? _status;

  /// The phone files' QRs, unfolded by their button.
  bool _apps = false;

  /// The nearby list has the focus or the pointer: shown fully, else faded.
  bool _nearby = false;

  @override
  void initState() {
    super.initState();
    final d = widget.session.devices;
    d.failed.addListener(_onFailed);
    // No network (or no local address) fails here: the reason shows, Skip and the nearby list still work.
    unawaited(
      d.startPairing().then(
        (qr) {
          if (mounted) setState(() => _qr = qr);
        },
        onError: (Object e) {
          if (mounted) {
            setState(
              () => _status = AppLocalizations.of(context).devicesFailed('$e'),
            );
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    final d = widget.session.devices;
    d.failed.removeListener(_onFailed);
    if (_qr != null) d.stopPairing();
    super.dispose();
  }

  void _onFailed() {
    final f = widget.session.devices.failed.value;
    if (f == null || !mounted) return;
    setState(() => _status = AppLocalizations.of(context).devicesFailed(f));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= Tokens.wideLayout;
    final phone = isPhone(context);
    final s = widget.session;

    final title = Row(
      children: [
        AppLogoMark(logo: s.logo, size: 56),
        const SizedBox(width: Tokens.space * 2),
        Expanded(
          child: Text(l10n.welcomeTitle, style: theme.textTheme.headlineMedium),
        ),
      ],
    );

    // The one instruction; the path names the same labels Settings shows.
    final instruction = Text(
      l10n.welcomeScan(
        '${l10n.navSettings} → ${l10n.settingsAccount} → ${l10n.devicesTitle}',
      ),
      style: theme.textTheme.titleMedium,
    );

    // This device's QR and code on an accent-tinted card (the user's accent: the scheme is seeded from it). Fixed to
    // the QR's width: its text (this device's name) wraps instead of widening the card (a long host name overflowed).
    final codeCard = SizedBox(
      width: 220 + Tokens.space * 4,
      child: Card(
        key: const Key('welcome.code'),
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radius * 1.5),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.space * 2),
          child: _qr != null
              ? PairCodeView(session: s, qr: _qr!)
              : SizedBox.square(
                  dimension: 220,
                  child: Center(
                    child: _status == null
                        ? const CircularProgressIndicator()
                        : const Icon(Icons.wifi_off, size: 48),
                  ),
                ),
        ),
      ),
    );

    // Skip takes the focus first (the remote's start); the line under it says where a login goes instead.
    final skip = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.tonalIcon(
          key: const Key('welcome.skip'),
          autofocus: true,
          icon: const Icon(Icons.arrow_forward),
          label: Text(l10n.welcomeSkip),
          onPressed: () => s.skipSetup(l10n.setupNoProvider),
        ),
        const SizedBox(height: Tokens.space),
        Text(
          l10n.welcomeNoDevice,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: Tokens.space),
            child: Text(
              _status!,
              key: const Key('welcome.status'),
              style: TextStyle(color: scheme.error),
            ),
          ),
      ],
    );

    // A phone doesn't need a QR for a phone. Folded behind one quiet button.
    final apps = phone
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                key: const Key('welcome.apps'),
                icon: Icon(_apps ? Icons.expand_less : Icons.phone_iphone),
                label: Text(l10n.welcomeGetApp),
                onPressed: () => setState(() => _apps = !_apps),
              ),
              if (_apps)
                Wrap(
                  spacing: Tokens.space * 3,
                  runSpacing: Tokens.space * 2,
                  children: [
                    for (final (platform, label) in [
                      ('android', l10n.welcomeAndroid),
                      ('ios', l10n.welcomeIphone),
                    ])
                      if (phoneFile(platform: platform) case final url?)
                        Row(
                          key: Key('welcome.get.$platform'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            QrView(text: url, size: 96),
                            const SizedBox(width: Tokens.space),
                            Flexible(
                              child: Text(
                                label,
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                          ],
                        ),
                  ],
                ),
            ],
          );

    // The devices found nearby, faded until the remote's focus or the pointer is in them (owner decision: a calm
    // first screen); a Focus that takes no focus itself hears when any tile inside gains or loses it.
    final nearby = MouseRegion(
      onEnter: (_) => setState(() => _nearby = true),
      onExit: (_) => setState(() => _nearby = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => setState(() => _nearby = f),
        child: AnimatedOpacity(
          key: const Key('welcome.nearby'),
          opacity: _nearby ? 1 : 0.4,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Tokens.motion,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Tokens.space * 2),
                child: Text(
                  l10n.welcomeFromHere,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              NearbyDevices(
                session: s,
                onStatus: (m) => setState(() => _status = m),
              ),
            ],
          ),
        ),
      ),
    );

    const gap = SizedBox(height: Tokens.space * 3);
    return Scaffold(
      // A soft accent glow from the top-left corner fading into the surface: the chosen accent colours the screen.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0, 0.6],
            // Opaque: the accent blended onto the surface here, so nothing below shines through.
            colors: [
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.18),
                scheme.surface,
              ),
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Tokens.space * 3),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 900 : 480),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                title,
                                gap,
                                instruction,
                                gap,
                                skip,
                                apps,
                                nearby,
                              ],
                            ),
                          ),
                          const SizedBox(width: Tokens.space * 4),
                          codeCard,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          title,
                          gap,
                          instruction,
                          const SizedBox(height: Tokens.space * 2),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: codeCard,
                          ),
                          gap,
                          skip,
                          apps,
                          nearby,
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
