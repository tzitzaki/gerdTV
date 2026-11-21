// Bootstrap journey: the app starts and the Rust core answers through flutter_rust_bridge.
// Runs on the Linux desktop build under Xvfb (just test-integration) and on the macOS CI runner.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('app starts and shows the core greeting', (tester) async {
    await tester.pumpWidget(const GerdTvApp());
    await tester.pumpAndSettle();
    expect(find.text('gerdTV'), findsOneWidget);
    expect(
      find.textContaining('Hello, gerdTV! This is gerdTV core'),
      findsOneWidget,
    );
  });
}
