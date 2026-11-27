// A fake Rust core for widget tests: flutter_rust_bridge's RustLib.initMock swaps the native library for this
// class, so widget tests run without building or loading libgerdtv_api. Add an override per API call a test needs;
// calls that aren't overridden throw (noSuchMethod), which points straight at the missing fake.
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:gerdtv/src/rust/api/tracking.dart';
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

  /// Saved profiles (profiles.json in the real core).
  var profiles = <ProfileInfo>[];

  @override
  Future<List<ProfileInfo>> crateApiLibraryListProfiles({
    required String dir,
  }) async => profiles;

  /// What Library.open returns (tests hand in a fake Library); null: opening fails.
  Library Function()? openLibrary;

  @override
  Future<Library> crateApiLibraryLibraryOpen({
    required String dir,
    required String profileId,
    required List<String> secrets,
  }) async => openLibrary?.call() ?? (throw 'FakeCore: no library to open');

  /// Deleted profiles' ids.
  final deleted = <String>[];

  @override
  Future<void> crateApiLibraryDeleteProfile({
    required String dir,
    required String id,
  }) async => deleted.add(id);

  /// Login checks: [loginError] is thrown (null: every login works); [saved] collects every saved profile.
  String? loginError;
  final saved = <ProfileInfo>[];

  @override
  Future<void> crateApiLibraryCheckLogin({
    required ProfileInfo profile,
    required List<String> secrets,
  }) async {
    if (loginError != null) throw loginError!;
  }

  @override
  Future<ProfileInfo> crateApiLibrarySaveProfile({
    required String dir,
    required ProfileInfo profile,
  }) async {
    saved.add(profile);
    return profile;
  }

  /// Premiumize: every key but "bad" is accepted (the real check asks Premiumize's account/info).
  @override
  Future<void> crateApiPremiumizePmCheck({required String token}) async {
    if (token == 'bad') throw 'Premiumize: authentication_failed';
  }

  /// Trakt/Simkl scrobbles as "service action progress"; [scrobbleRefresh] is returned as a refreshed token.
  final scrobbles = <String>[];
  String? scrobbleRefresh;

  @override
  Future<String?> crateApiTrackingTrackScrobble({
    required String service,
    required String clientId,
    required String clientSecret,
    required String token,
    required String action,
    required TrackItem item,
    required double progress,
  }) async {
    scrobbles.add('$service $action ${progress.round()}');
    return scrobbleRefresh;
  }

  /// Simkl history calls as "watched key", and the token they return (a refresh).
  final history = <String>[];

  @override
  Future<String?> crateApiTrackingSimklHistory({
    required String clientId,
    required String token,
    required TrackItem item,
    required bool watched,
  }) async {
    history.add('$watched ${item.name}');
    return null;
  }

  @override
  String crateApiUpdateReleasePage() =>
      'https://example.invalid/releases/latest';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeCore: no fake for ${invocation.memberName}',
  );
}

FakeCore? _core;

/// Installs [FakeCore] (or a test's subclass, [core]) once per test process (RustLib can only be initialised once)
/// and returns it.
FakeCore useFakeCore([FakeCore? core]) {
  if (_core == null) RustLib.initMock(api: _core = core ?? FakeCore());
  return _core!;
}
