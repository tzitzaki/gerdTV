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

  /// App-wide settings (app.json in the real core), by key; tests read what the UI stored.
  final appSettings = <String, String>{};

  @override
  String? crateApiLibraryAppSetting({
    required String dir,
    required String key,
  }) => appSettings[key];

  @override
  void crateApiLibrarySetAppSetting({
    required String dir,
    required String key,
    required String value,
  }) => appSettings[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeCore: no fake for ${invocation.memberName}',
  );
}

FakeCore? _core;

/// Installs [FakeCore] once per test process (RustLib can only be initialised once) and returns it.
FakeCore useFakeCore() {
  if (_core == null) RustLib.initMock(api: _core = FakeCore());
  return _core!;
}
