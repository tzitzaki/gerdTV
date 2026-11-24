// New, because nothing owned screen-change motion: every route takes Tokens.motion (docs/DESIGN.md) and is fully
// shown right after; wide windows fade on every platform, phones (iOS, Android below the wide layout) slide and close
// with a swipe from the left edge (owner decision), and reduced motion shows the page without a transition.
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
    testWidgets('routes fade in Tokens.motion on ${platform.name}', (
      tester,
    ) async {
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
      // Fully shown after Tokens.motion (a platform slide would be half-way); the status turns "completed" a tick later.
      expect(
        route.animation!.value,
        1.0,
        reason: 'fully shown after Tokens.motion',
      );
      expect(find.byType(FadeTransition), findsWidgets);
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('phones swipe back from the left edge on ${platform.name}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: gerdTheme(Brightness.dark),
          home: const Scaffold(body: Text('home')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('next'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FadeTransition), findsNothing, reason: 'a slide');
      // A drag from the left edge across most of the screen closes the page.
      await tester.dragFrom(const Offset(5, 400), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('next'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });
  }

  testWidgets('reduced motion shows the page without a transition', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          navigatorKey: nav,
          theme: gerdTheme(Brightness.dark),
          home: const Text('home'),
        ),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('next')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(FadeTransition), findsNothing);
  });
}
