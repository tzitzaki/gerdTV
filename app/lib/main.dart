// gerdTV app entry point: loads the Rust core and libmpv, opens the saved account (cache first, then a background
// sync) or shows the first-run setup.
//
// Debug hints: a crash before the first frame in RustLib.init() means the native library wasn't bundled or found
// (Cargokit, app/rust_builder; see docs/ARCHITECTURE.md, "The seam"). Missing German strings: app/lib/l10n/*.arb.

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/gen/app_localizations.dart';
import 'screens/now_playing_bar.dart';
import 'screens/setup_screen.dart';
import 'screens/shell.dart';
import 'services/session.dart';
import 'src/rust/api/logos.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Logos and posters are kept on disk (the OS may clear this folder; they are fetched again then).
  initLogoCache(dir: '${(await getApplicationCacheDirectory()).path}/logos');
  MediaKit.ensureInitialized();
  final session = Session()..start();
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
      // The now-playing bar below every screen (playback continues until Stop or another stream).
      builder: (context, child) => Column(
        children: [
          Expanded(child: child!),
          NowPlayingBar(session: session),
        ],
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
