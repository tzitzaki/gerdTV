// gerdTV app entry point. Bootstrap state: loads the Rust core (flutter_rust_bridge) and shows its greeting, which
// proves the native library builds and loads on every platform. The real shell (docs/SPEC.md) replaces this screen.
//
// Debug hints: a crash before the first frame in RustLib.init() means the native library wasn't bundled or found
// (Cargokit, app/rust_builder; see docs/ARCHITECTURE.md, "The seam"). Missing German strings: app/lib/l10n/*.arb.

import 'package:material_ui/material_ui.dart';

import 'l10n/gen/app_localizations.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const GerdTvApp());
}

class GerdTvApp extends StatelessWidget {
  const GerdTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // The window/task title; the visible name is "gerdTV" in every language.
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      // Not AppLocalizations.localizationsDelegates: gen-l10n still lists flutter_localizations' Material delegate,
      // whose type material_ui widgets don't find ("No MaterialLocalizations found"). material_ui's own list instead.
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(brightness: Brightness.dark),
      home: const _HelloScreen(),
    );
  }
}

class _HelloScreen extends StatelessWidget {
  const _HelloScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(child: Text(l10n.coreGreeting(greet(name: 'gerdTV')))),
    );
  }
}
