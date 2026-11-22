// Shared by the integration tests: the mock panel's address, in-memory secrets, and waiting in real time.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/secrets.dart';

const mockXc = String.fromEnvironment('GERDTV_MOCK_XC');

/// Headless runners have no keyring for libsecret; the journey keeps secrets in memory instead.
class MemorySecrets extends Secrets {
  final _m = <String, List<String>>{};
  @override
  Future<void> write(String profileId, List<String> secrets) async =>
      _m[profileId] = secrets;
  @override
  Future<List<String>?> read(String profileId) async => _m[profileId];
  @override
  Future<void> delete(String profileId) async => _m.remove(profileId);
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
