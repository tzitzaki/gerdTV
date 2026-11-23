// gerdTV app entry point: loads the Rust core and libmpv, opens the saved account (cache first, then a background
// sync) or shows the first-run setup.
//
// Debug hints: a crash before the first frame in RustLib.init() means the native library wasn't bundled or found
// (Cargokit, app/rust_builder; see docs/ARCHITECTURE.md, "The seam"). Missing German strings: app/lib/l10n/*.arb.

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/gen/app_localizations.dart';
import 'licences.dart';
import 'platform/sandbox_migration.dart';
import 'screens/now_playing_bar.dart';
import 'screens/player_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/shell.dart';
import 'services/reminders.dart';
import 'services/session.dart';
import 'src/rust/api/logos.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  registerBundledLicences();
  // Logos and posters are kept on disk (the OS may clear this folder; they are fetched again then).
  initLogoCache(dir: '${(await getApplicationCacheDirectory()).path}/logos');
  MediaKit.ensureInitialized();
  if (Platform.isMacOS) {
    // First start without the sandbox: copy the old container's data over (see sandbox_migration.dart).
    final copied = migrateSandboxData(
      sandboxSupportDir(
        Platform.environment['HOME'] ?? '',
        'world.zakis.gerdtv',
      ),
      await getApplicationSupportDirectory(),
    );
    if (copied > 0) debugPrint('sandbox-migration: copied $copied files');
  }
  final session = Session();
  // A tapped reminder plays its channel (it may have left the catalogue since: then nothing happens).
  session.reminders = Reminders(
    onOpen: (key) async {
      final item = await session.library?.item(key: key);
      if (item == null) return;
      await session.navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(session: session, item: item),
        ),
      );
    },
  );
  unawaited(session.reminders!.init());
  unawaited(session.start());
  session.platform.attach();
  runApp(GerdTvApp(session: session));
}

class GerdTvApp extends StatelessWidget {
  const GerdTvApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: session.navigatorKey,
      // The now-playing bar below every screen (playback continues until Stop or another stream), and one focus
      // policy for every route, sheet and menu (see revealFocus).
      builder: (context, child) => FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(requestFocusCallback: revealFocus),
        child: Column(
          children: [
            Expanded(child: child!),
            NowPlayingBar(session: session),
          ],
        ),
      ),
      // The window/task title; the visible name is "gerdTV" in every language.
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      // Not AppLocalizations.localizationsDelegates: gen-l10n still lists flutter_localizations' Material delegate,
      // whose type material_ui widgets don't find ("No MaterialLocalizations found"). material_ui's own list instead.
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: gerdTheme(Brightness.light),
      darkTheme: gerdTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: ListenableBuilder(
        listenable: session,
        builder: (context, _) => switch (session.state) {
          SessionState.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          SessionState.needsSetup => SetupScreen(session: session),
          SessionState.ready => Shell(session: session),
        },
      ),
    );
  }
}

/// Moves focus and scrolls the target into view from either side. Flutter's own Tab step only scrolls when the
/// target lies past the end of the view, but in a scrolled list the next control in reading order can lie above it
/// (built just off-screen): keyboard and remote users then lost sight of the focus (found by the screen check).
/// Both steps do nothing for a target that is already visible, so visible moves never jump.
void revealFocus(
  FocusNode node, {
  ScrollPositionAlignmentPolicy? alignmentPolicy,
  double? alignment,
  Duration? duration,
  Curve? curve,
}) {
  node.requestFocus();
  final context = node.context;
  if (context == null) return;
  for (final policy in const [
    ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  ]) {
    Scrollable.ensureVisible(
      context,
      alignmentPolicy: policy,
      duration: duration ?? Duration.zero,
      curve: curve ?? Curves.ease,
    );
  }
}
