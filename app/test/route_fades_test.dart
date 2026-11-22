// New, because nothing owned screen-change motion: every route fades in Tokens.motion (150 ms, docs/DESIGN.md), on
// every platform, and is fully shown right after.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('routes fade in 150 ms on ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: gerdTheme(Brightness.dark),
          home: const Text('home'),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('next')),
      );
      await tester.pump();
      // (In the push's first frame the route is still offstage.)
      final route = ModalRoute.of(
        tester.element(find.text('next', skipOffstage: false)),
      )!;
      expect(route.transitionDuration, Tokens.motion);
      await tester.pump(Tokens.motion);
      // Fully opaque after 150 ms (a 300 ms slide would be half-way); the status turns "completed" a tick later.
      expect(route.animation!.value, 1.0, reason: 'fully shown after 150 ms');
      expect(find.byType(FadeTransition), findsWidgets);
    });
  }
}
