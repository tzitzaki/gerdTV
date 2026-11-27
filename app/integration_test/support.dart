// Shared by the integration tests: the mock panel's address, in-memory secrets, and waiting in real time.
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:material_ui/material_ui.dart';

const mockXc = String.fromEnvironment('GERDTV_MOCK_XC');

/// Headless runners have no keyring for libsecret: secrets stay in memory, linked services' too (the Linux plugin
/// takes the app down on the first service read without a secret service, e.g. opening a profile without provider
/// after Skip).
class MemorySecrets extends Secrets {
  final _m = <String, List<String>>{};
  final _services = <String, String>{};
  @override
  Future<void> write(String profileId, List<String> secrets) async =>
      _m[profileId] = secrets;
  @override
  Future<List<String>?> read(String profileId) async => _m[profileId];
  @override
  Future<void> delete(String profileId) async => _m.remove(profileId);
  @override
  Future<String?> readService(String profileId, String service) async =>
      _services['$service.$profileId'];
  @override
  Future<void> writeService(
    String profileId,
    String service,
    String? token,
  ) async => token == null
      ? _services.remove('$service.$profileId')
      : _services['$service.$profileId'] = token;
}

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

/// Desktop: Stop sits in media_kit's bar, which shows while the mouse moves over the picture.
Future<void> tapStop(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  final centre = tester.getCenter(find.byType(Scaffold).last);
  await mouse.addPointer(location: centre);
  await mouse.moveTo(centre + const Offset(5, 5));
  await tapReady(tester, find.byKey(const Key('player.stop')));
  await mouse.removePointer();
}
