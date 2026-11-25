// Profile secrets (Xtream Codes login, an M3U URL with credentials) in the platform's secure storage: Keychain on
// Apple, Keystore-backed on Android, libsecret on Linux. They're handed to the Rust core at runtime and kept only
// in memory there; never in files, logs or the profile list.
//
// macOS: Apple's security tool instead of the plugin (lib/platform/mac_keychain.dart says why). Values the plugin
// stored before are moved on first read: one last prompt each, then the old item is deleted.
// Debug hints: the old macOS items are in the legacy keychain (usesDataProtectionKeychain: false, service
// flutter_secure_storage_service): the data protection keychain needs a provisioning profile, which a self-signed
// build doesn't have. After re-signing an iOS build with a different certificate the stored values can't be read:
// `read` returns null and the app asks for the login again.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/mac_keychain.dart';

class Secrets {
  Secrets([FlutterSecureStorage? storage, MacKeychain? mac])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          ),
      _mac = mac ?? (Platform.isMacOS ? const MacKeychain() : null);

  final FlutterSecureStorage _storage; // on macOS only the old place
  final MacKeychain? _mac; // null on every other platform

  Future<String?> _read(String key) async {
    final mac = _mac;
    if (mac == null) return _storage.read(key: key);
    final value = await mac.read(key);
    if (value != null) return value;
    final old = await _storage.read(key: key);
    if (old != null) {
      try {
        await _write(key, old);
      } catch (_) {
        // Not moved: the old item is still there and the next start tries again.
      }
    }
    return old;
  }

  Future<void> _write(String key, String value) async {
    final mac = _mac;
    if (mac == null) return _storage.write(key: key, value: value);
    await mac.write(key, value); // throws unless it reads back, so the old item is only deleted after that
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // A leftover is harmless: the new item wins.
    }
  }

  /// Both places, the old one first: if that fails, the new item is still there and nothing comes back to life.
  Future<void> _delete(String key) async {
    await _storage.delete(key: key);
    await _mac?.delete(key);
  }

  String _key(String profileId) => 'gerdtv.profile.$profileId';

  Future<void> write(String profileId, List<String> secrets) =>
      _write(_key(profileId), jsonEncode(secrets));

  /// The profile's secrets, or null when missing or unreadable (e.g. after an iOS re-sign).
  Future<List<String>?> read(String profileId) async {
    try {
      final v = await _read(_key(profileId));
      return v == null ? null : (jsonDecode(v) as List).cast<String>();
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String profileId) => _delete(_key(profileId));

  /// A linked service's token for a profile ([service]: "premiumize", "trakt", "simkl"); null when there is none
  /// or it can't be read. Kept apart from the provider login, so linking or unlinking never touches that.
  Future<String?> readService(String profileId, String service) async {
    try {
      return await _read('gerdtv.$service.$profileId');
    } catch (_) {
      return null;
    }
  }

  Future<void> writeService(String profileId, String service, String? token) =>
      token == null
      ? _delete('gerdtv.$service.$profileId')
      : _write('gerdtv.$service.$profileId', token);
}
