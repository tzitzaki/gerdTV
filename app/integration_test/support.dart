// Shared by the integration tests: the mock panel's address, in-memory secrets, and waiting in real time.
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// The one in-memory Secrets, shared with the widget tests.
export '../test/support/memory_secrets.dart';

const mockXc = String.fromEnvironment('GERDTV_MOCK_XC');

/// Pumps frames in real time until [found] appears.
Future<void> waitFor(
  WidgetTester tester,
  Finder found, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (found.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $found');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// Waits until [found] can take a tap at its centre, then taps the first such match. Routes and sheets slide in (macOS from the right,
/// sheets from below): a widget that merely exists may still be outside the window, and the tap would miss.
Future<void> tapReady(WidgetTester tester, Finder found) async {
  await waitFor(tester, found.hitTestable());
  await tester.tap(found.hitTestable().first);
}

/// A player control: media_kit's bar and gerdTV's top bar show while the mouse moves over the picture (the top bar
/// fades 3 s after the last activity, ActivityScope), so the mouse moves first.
Future<void> tapControl(WidgetTester tester, Finder found) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  final centre = tester.getCenter(find.byType(Scaffold).last);
  await mouse.addPointer(location: centre);
  await mouse.moveTo(centre + const Offset(5, 5));
  await tapReady(tester, found);
  await mouse.removePointer();
}

/// Desktop: Stop sits in media_kit's bar.
Future<void> tapStop(WidgetTester tester) =>
    tapControl(tester, find.byKey(const Key('player.stop')));
