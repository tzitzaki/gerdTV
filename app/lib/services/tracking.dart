// Watch tracking with Trakt and Simkl (owner request): linked per profile in Settings → Account (a device code),
// then every movie and episode is scrobbled: start when it starts or resumes, pause on a pause, stop with the
// progress when it ends or another starts. The core cleans the titles and talks to the services
// (gerdtv_core::tracking); this holds the tokens (secure storage, as JSON with their refresh token) and calls it.
// No client id or secret is in the repository or the builds (owner decision: the repo is public, an app's secrets
// can be extracted, and a shared id could be suspended for everyone): each user links their own app per service
// (Trakt: client id and secret; Simkl: client id only, its device login needs no secret), typed in Settings and kept
// in the device's secure storage like the tokens.
// From Simkl, watched marks and paused positions also come in (importSimkl), and marks made by hand go out (history).
// Debugging: a failed scrobble only prints "tracking: <service> <action>: <reason>" to the debug log; playback
// never waits for it.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api/library.dart';
import '../src/rust/api/tracking.dart';
import 'secrets.dart';

/// A tracking service gerdTV knows: its storage and core name, what the user sees, and whether the user's own app
/// needs a client secret besides its id.
class TrackService {
  const TrackService(this.id, this.label, {this.needsSecret = false});
  final String id;
  final String label;
  final bool needsSecret;
}

const trackServices = [
  TrackService('trakt', 'Trakt', needsSecret: true),
  TrackService('simkl', 'Simkl'),
];

class Tracking extends ChangeNotifier {
  Tracking(this._secrets, {this.services = trackServices});
  final Secrets _secrets;

  /// The services offered (tests pass their own).
  final List<TrackService> services;

  String? _profile;

  /// Token JSON per linked service id.
  final Map<String, String> tokens = {};

  /// The user's own app per service: (client id, client secret; '' where none is needed).
  final Map<String, (String, String)> apps = {};

  bool linked(TrackService s) => tokens.containsKey(s.id);

  /// The client id and secret to use for [s]: the user's own app (null: none yet).
  (String, String)? client(TrackService s) => apps[s.id];

  /// Stores the user's own app for [s] (or forgets it with null).
  Future<void> setApp(TrackService s, (String, String)? app) async {
    final p = _profile;
    if (p == null) return;
    await _secrets.writeService(
      p,
      '${s.id}-app',
      app == null ? null : jsonEncode([app.$1.trim(), app.$2.trim()]),
    );
    app == null
        ? apps.remove(s.id)
        : apps[s.id] = (app.$1.trim(), app.$2.trim());
    notifyListeners();
  }

  /// Reads the profile's links (when it opens).
  Future<void> load(String profileId) async {
    _profile = profileId;
    tokens.clear();
    apps.clear();
    for (final s in services) {
      final t = await _secrets.readService(profileId, s.id);
      if (t != null) tokens[s.id] = t;
      final app = await _secrets.readService(profileId, '${s.id}-app');
      if (app == null) continue;
      final pair = (jsonDecode(app) as List).cast<String>();
      apps[s.id] = (pair[0], pair[1]);
    }
    notifyListeners();
  }

  /// Stores [token] (JSON from the device login) or unlinks with null.
  Future<void> link(TrackService s, String? token) async {
    final p = _profile;
    if (p == null) return;
    await _secrets.writeService(p, s.id, token);
    token == null ? tokens.remove(s.id) : tokens[s.id] = token;
    notifyListeners();
  }

  /// Deletes the open profile's links and own apps (its removal); only keys that exist (see Session.removeProfile).
  Future<void> forget() async {
    for (final s in services) {
      if (tokens.containsKey(s.id)) await link(s, null);
      if (apps.containsKey(s.id)) await setApp(s, null);
    }
    _profile = null;
  }

  /// Simkl's watched marks and paused positions (core: watch_import.rs): after each sync, at most every 30 min
  /// (Simkl's rule), or at once with [force] (the settings button). Returns what it took, null when Simkl isn't
  /// linked, wasn't due or had nothing new. Never throws: a failure is in the debug log.
  Future<SimklImport?> importSimkl(Library lib, {bool force = false}) async {
    final s = services.firstWhere((s) => s.id == 'simkl');
    final token = tokens[s.id];
    final c = client(s);
    if (token == null || c == null) return null;
    try {
      final n = await lib.simklImport(
        clientId: c.$1,
        token: token,
        force: force,
      );
      if (n?.token case final fresh?) await link(s, fresh);
      return n;
    } catch (e) {
      debugPrint('tracking: simkl import: $e');
      return null;
    }
  }

  /// A movie or episode marked as watched by hand, or unmarked, goes to Simkl's history. Never throws.
  Future<void> history(Library lib, String key, bool watched) async {
    final s = services.firstWhere((s) => s.id == 'simkl');
    final token = tokens[s.id];
    final c = client(s);
    if (token == null || c == null) return;
    try {
      final item = await lib.trackItem(key: key);
      if (item == null) return;
      final fresh = await simklHistory(
        clientId: c.$1,
        token: token,
        item: item,
        watched: watched,
      );
      if (fresh != null) await link(s, fresh);
    } catch (e) {
      debugPrint('tracking: simkl history: $e');
    }
  }

  /// Tells every linked service [action] ("start", "pause", "stop") for [key] at [progress] (0–100); items that
  /// aren't movies or episodes are skipped. Never throws.
  Future<void> scrobble(
    Library lib,
    String key,
    String action,
    double progress,
  ) async {
    if (tokens.isEmpty) return;
    final TrackItem? item;
    try {
      item = await lib.trackItem(key: key);
    } catch (_) {
      return;
    }
    if (item == null) return;
    for (final s in services) {
      final token = tokens[s.id];
      final c = client(s);
      if (token == null || c == null) continue;
      try {
        final fresh = await trackScrobble(
          service: s.id,
          clientId: c.$1,
          clientSecret: c.$2,
          token: token,
          action: action,
          item: item,
          progress: progress,
        );
        if (fresh != null) await link(s, fresh);
      } catch (e) {
        debugPrint('tracking: ${s.id} $action: $e');
      }
    }
  }
}
