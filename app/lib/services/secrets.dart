// Profile secrets (Xtream Codes login, an M3U URL with credentials) in the platform's secure storage: Keychain on
// Apple, Keystore-backed on Android, libsecret on Linux. They're handed to the Rust core at runtime and kept only
// in memory there; never in files, logs or the profile list.
//
// Debug hints: macOS uses the legacy keychain (usesDataProtectionKeychain: false): the data protection keychain
// needs a provisioning profile, which a self-signed build doesn't have. After re-signing an iOS build with a
// different certificate the stored values can't be read: `read` returns null and the app asks for the login again.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Secrets {
  Secrets([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  String _key(String profileId) => 'gerdtv.profile.$profileId';

  Future<void> write(String profileId, List<String> secrets) =>
      _storage.write(key: _key(profileId), value: jsonEncode(secrets));

  /// The profile's secrets, or null when missing or unreadable (e.g. after an iOS re-sign).
  Future<List<String>?> read(String profileId) async {
    try {
      final v = await _storage.read(key: _key(profileId));
      return v == null ? null : (jsonDecode(v) as List).cast<String>();
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String profileId) =>
      _storage.delete(key: _key(profileId));
}
