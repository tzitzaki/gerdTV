// First run: bring the provider over from a device that already has gerdTV, nothing to type (owner decision: no
// provider form on first run). This device listens at once and shows its QR and code (PairCodeView), three numbered
// steps say what to do on the other device, and NearbyDevices pairs from this side with a device that shows a code;
// both are the Devices & sync page's own widgets (devices_screen.dart). A finished sync opens the provider that came
// (Session's apply path), which replaces this screen with the app. Skip to the app opens gerdTV without a provider
// (Session.skipSetup); the login is then added in Settings → Account (the setup form). On a TV or computer a second
// part offers this version's phone files as QRs (Android APK, iPhone IPA), so a phone without gerdTV gets the build
// that pairs with this one.
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

    final header = Row(
      children: [
        AppLogoMark(logo: s.logo, size: 64),
        const SizedBox(width: Tokens.space * 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.welcomeTitle, style: theme.textTheme.headlineMedium),
              const SizedBox(height: Tokens.space / 2),
              Text(
                l10n.welcomeIntro,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    // The three steps on the other device; the path names the same labels Settings shows.
    final steps = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Step(n: 1, text: l10n.welcomeStep1),
        _Step(
          n: 2,
          text: l10n.welcomeStep2(
            '${l10n.navSettings} → ${l10n.settingsAccount} → ${l10n.devicesTitle}',
          ),
        ),
        _Step(n: 3, text: l10n.welcomeStep3(s.devices.me.name)),
      ],
    );

    // This device's QR and code on an accent-tinted card (the user's accent: the scheme is seeded from it).
    final codeCard = Card(
      key: const Key('welcome.code'),
      elevation: 0,
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
    );

    final nearby = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l10n.welcomeFromHere),
        NearbyDevices(session: s, onStatus: (m) => setState(() => _status = m)),
      ],
    );

    // A phone doesn't need a QR for a phone.
    final downloads = phone
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Heading(l10n.welcomeGetApp),
              Wrap(
                spacing: Tokens.space * 3,
                runSpacing: Tokens.space * 2,
                children: [
                  for (final (platform, label) in [
                    ('android', l10n.welcomeAndroid),
                    ('ios', l10n.welcomeIphone),
                  ])
                    if (phoneFile(platform: platform) case final url?)
                      Column(
                        key: Key('welcome.get.$platform'),
                        children: [
                          QrView(text: url, size: 120),
                          const SizedBox(height: Tokens.space),
                          Text(label, style: theme.textTheme.labelLarge),
                        ],
                      ),
                ],
              ),
            ],
          );

    // Skip first in focus order (autofocus), so the remote has a start; the hint says where logins go instead.
    final skip = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.welcomeNoDevice, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Tokens.space * 1.5),
        FilledButton.tonalIcon(
          key: const Key('welcome.skip'),
          autofocus: true,
          icon: const Icon(Icons.arrow_forward),
          label: Text(l10n.welcomeSkip),
          onPressed: () => s.skipSetup(l10n.setupNoProvider),
        ),
      ],
    );

    final status = _status == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: Tokens.space * 2),
            child: Text(
              _status!,
              key: const Key('welcome.status'),
              style: TextStyle(color: scheme.error),
            ),
          );

    const gap = SizedBox(height: Tokens.space * 3);
    return Scaffold(
      // A soft accent glow from the top-left corner into the surface: the chosen accent colours the first screen.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [scheme.primary.withValues(alpha: 0.16), scheme.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Tokens.space * 3),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    gap,
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [steps, gap, skip, status, nearby],
                            ),
                          ),
                          const SizedBox(width: Tokens.space * 4),
                          // Fixed width: the QR card (220 + padding) and the two phone QRs side by side.
                          SizedBox(
                            width: 290,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [codeCard, downloads],
                            ),
                          ),
                        ],
                      )
                    else ...[
                      steps,
                      const SizedBox(height: Tokens.space * 2),
                      Align(alignment: Alignment.centerLeft, child: codeCard),
                      gap,
                      skip,
                      status,
                      nearby,
                      downloads,
                    ],
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

/// One numbered step: the number in an accent circle, the text beside it.
class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.space * 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            child: Text(
              '$n',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: Tokens.space * 1.5),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(text, style: theme.textTheme.titleMedium),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Tokens.space * 3, bottom: Tokens.space),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
