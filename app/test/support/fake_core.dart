// A fake Rust core for widget tests: flutter_rust_bridge's RustLib.initMock swaps the native library for this
// class, so widget tests run without building or loading libgerdtv_api. Add an override per API call a test needs;
// calls that aren't overridden throw (noSuchMethod), which points straight at the missing fake.
import 'package:gerdtv/src/rust/frb_generated.dart';

class FakeCore implements RustLibApi {
  @override
  String crateApiSimpleGreet({required String name}) =>
      'fake greeting for $name';

  @override
  String crateApiSimpleCoreVersion() => '0.0.0-fake';

  @override
  Future<void> crateApiSimpleInitApp() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeCore: no fake for ${invocation.memberName}',
  );
}

bool _initialised = false;

/// Installs [FakeCore] once per test process (RustLib can only be initialised once).
void useFakeCore() {
  if (_initialised) return;
  RustLib.initMock(api: FakeCore());
  _initialised = true;
}
