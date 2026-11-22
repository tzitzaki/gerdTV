// The app's state: the open profile's library, its sync status, and the one media_kit player the whole app uses
// (zapping replaces the media; a second Player in one process misbehaved, see docs/HANDOVER.md).
// Plain ChangeNotifier (docs/DECISIONS.md: no state-management packages).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../player/watchdog_adapter.dart';
import '../src/rust/api/library.dart';
import 'secrets.dart';

enum SessionState { loading, needsSetup, ready }

class Session extends ChangeNotifier {
  Session({Secrets? secrets, this.appDir}) : secrets = secrets ?? Secrets();

  final Secrets secrets;

  /// The app-support folder (profiles.json, profile databases). Set in tests; else from path_provider.
  String? appDir;

  SessionState state = SessionState.loading;
  ProfileInfo? profile;
  Library? library;

  /// True while a sync runs; the UI keeps showing the cached catalogue meanwhile.
  bool syncing = false;

  /// The last sync's outcome for the user (an error message, or null when fine).
  String? syncError;
  SyncSummary? lastSync;

  /// Bumped after each sync so lists reload.
  int generation = 0;

  Player? _player;
  VideoController? _video;
  WatchdogAdapter? _adapter;

  Player get player =>
      _player ??= Player(configuration: WatchdogAdapter.playerConfiguration);
  VideoController get video => _video ??= VideoController(player);
  WatchdogAdapter get adapter => _adapter ??= WatchdogAdapter(
    player,
    onHealth: (trigger, attempts, recovered, secs) {
      final key = _playingKey;
      if (key != null) {
        unawaited(
          library?.recordHealth(
            key: key,
            trigger: trigger,
            attempts: attempts,
            recovered: recovered,
            secs: secs,
          ),
        );
      }
    },
    onRememberHls: (hls) {
      final key = _playingKey;
      if (key != null) unawaited(library?.setPreferHls(key: key, hls: hls));
    },
  );
  String? _playingKey;

  Future<String> _dir() async =>
      appDir ??= (await getApplicationSupportDirectory()).path;

  /// Opens the first profile whose secrets are readable; otherwise asks for setup.
  Future<void> start() async {
    final dir = await _dir();
    final profiles = await listProfiles(dir: dir);
    for (final p in profiles) {
      final s = await secrets.read(p.id);
      if (s == null && p.source != SourceKind.m3UFile) continue;
      if (await _open(p, s ?? const [])) {
        unawaited(sync()); // cache first, then refresh in the background
        return;
      }
    }
    state = SessionState.needsSetup;
    notifyListeners();
  }

  Future<bool> _open(ProfileInfo p, List<String> s) async {
    try {
      library = await Library.open(
        dir: await _dir(),
        profileId: p.id,
        secrets: s,
      );
      profile = p;
      state = SessionState.ready;
      notifyListeners();
      return true;
    } catch (e) {
      syncError = '$e';
      return false;
    }
  }

  /// Saves a new profile and its secrets, opens it and runs the first sync. Returns an error message or null.
  /// A failed first sync (wrong login, unreachable server) removes the profile again, so the form can be retried.
  Future<String?> addProfile(
    ProfileInfo info,
    List<String> profileSecrets,
  ) async {
    final dir = await _dir();
    final saved = await saveProfile(dir: dir, profile: info);
    await secrets.write(saved.id, profileSecrets);
    final lib = await Library.open(
      dir: dir,
      profileId: saved.id,
      secrets: profileSecrets,
    );
    try {
      lastSync = await lib.sync_();
    } catch (e) {
      await deleteProfile(dir: dir, id: saved.id);
      await secrets.delete(saved.id);
      return '$e';
    }
    library = lib;
    profile = saved;
    syncError = null;
    generation++;
    state = SessionState.ready;
    notifyListeners();
    return null;
  }

  Future<void> sync() async {
    final lib = library;
    if (lib == null || syncing) return;
    syncing = true;
    syncError = null;
    notifyListeners();
    try {
      lastSync = await lib.sync_();
      generation++;
    } catch (e) {
      syncError = '$e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Removes the current profile, its database and its secrets (the UI confirms first).
  Future<void> removeProfile() async {
    final p = profile;
    if (p == null) return;
    await stopPlayback();
    await deleteProfile(dir: await _dir(), id: p.id);
    await secrets.delete(p.id);
    library = null;
    profile = null;
    state = SessionState.needsSetup;
    notifyListeners();
  }

  /// Plays an item through the watchdog. Live channels use the URL form that worked last time.
  Future<void> play(ItemInfo item) async {
    final lib = library;
    if (lib == null) return;
    _playingKey = item.key;
    final live = item.kind == ItemKind.live;
    final preferHls = live && lib.preferHls(key: item.key);
    await adapter.play(
      ({required hls}) => lib.streamUrl(key: item.key, preferHls: hls),
      live: live,
      preferHls: preferHls,
    );
  }

  Future<void> stopPlayback() async {
    _playingKey = null;
    await _adapter?.stop();
    await _player?.stop();
  }

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }
}

/// True on desktop platforms (window-sized layouts, keyboard first).
bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);
