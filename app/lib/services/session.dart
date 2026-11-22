// The app's state: the open profile's library, its sync status, and the one media_kit player the whole app uses
// (zapping replaces the media; a second Player in one process misbehaved, see docs/HANDOVER.md).
// Plain ChangeNotifier (docs/DECISIONS.md: no state-management packages).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/platform_bridge.dart';
import '../player/watchdog_adapter.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
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

  /// True while the guide downloads and imports (Settings → Guide shows it; lists keep their old now/next).
  bool guideRefreshing = false;

  /// Bumped after each guide import so now/next and the grid reload.
  int guideGeneration = 0;

  /// Checks hourly whether the guide is older than [guideMaxAge] (the app may stay open for days).
  Timer? _guideTimer;

  /// The guide is refreshed when its oldest source is older than this (and once a profile is open without one).
  static const guideMaxAge = Duration(hours: 12);

  /// Days of guide kept ahead: a week on desktop, 3 days on phones and TVs (smaller storage, slower imports).
  static int get guideDaysAhead => isDesktop ? 7 : 3;

  Player? _player;
  VideoController? _video;
  WatchdogAdapter? _adapter;

  Player get player =>
      _player ??= Player(configuration: WatchdogAdapter.playerConfiguration);

  /// Software video rendering, only for CI: GitHub's macOS runners are VMs without a usable GPU, and the hardware
  /// texture stalled there (`just mac-check` sets GERDTV_SOFTWARE_VIDEO). Real devices use hardware rendering.
  static const _softwareVideo = bool.fromEnvironment('GERDTV_SOFTWARE_VIDEO');

  VideoController get video => _video ??= VideoController(
    player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: !_softwareVideo,
    ),
  );
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

  /// What is playing right now, or null. Playback only ends by Stop or by starting another stream (owner decision):
  /// leaving the player screen keeps it running, shown by the now-playing bar in the shell.
  final ValueNotifier<ItemInfo?> nowPlaying = ValueNotifier(null);

  /// Adaptive mode raised the current channel's buffer to this many seconds (the player shows a short notice).
  final ValueNotifier<int?> bufferRaisedTo = ValueNotifier(null);

  /// True while the full player screen is open (the now-playing bar hides then).
  final ValueNotifier<bool> playerOpen = ValueNotifier(false);

  /// True while only the picture is shown: the desktop floating mini player, or system Picture-in-Picture.
  final ValueNotifier<bool> pictureMode = ValueNotifier(false);

  /// Native background playback / Picture-in-Picture (Android); attached in main().
  late final PlatformBridge platform = PlatformBridge(pictureMode: pictureMode);

  /// The app's navigator: the now-playing bar sits below all routes (MaterialApp.builder) and opens the player here.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
    unawaited(
      refreshGuide(),
    ); // the first guide loads while the user starts browsing
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
    await refreshGuide();
  }

  /// Refreshes the guide when it is missing or older than [guideMaxAge] (or always with [force]: "Refresh now").
  /// Failures are kept per source (Settings → Guide shows them); the previous guide stays meanwhile.
  Future<void> refreshGuide({bool force = false}) async {
    final lib = library;
    _guideTimer ??= Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(refreshGuide()),
    );
    if (lib == null || guideRefreshing) return;
    final age = await lib.guideAge();
    if (!force && age != null && age < guideMaxAge.inSeconds) return;
    guideRefreshing = true;
    notifyListeners();
    try {
      await lib.refreshGuide(daysAhead: guideDaysAhead);
      guideGeneration++;
    } catch (e) {
      debugPrint(
        'guide refresh: $e',
      ); // a database error; download errors are recorded per source instead
    } finally {
      guideRefreshing = false;
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
    if (nowPlaying.value?.key == item.key) {
      return; // reopening the player for the running stream: keep it going
    }
    nowPlaying.value = item;
    _playingKey = item.key;
    await _start(item, lib);
  }

  /// Plays a programme from the channel's catch-up archive, from its start (false when there is none: no archive,
  /// out of reach, or not Xtream Codes). It plays like a recording: seekable, no live timeshift; the channel's own
  /// buffer applies. The now-playing item is the programme on its channel.
  Future<bool> playCatchup(ItemInfo channel, ProgrammeInfo p) async {
    final lib = library;
    if (lib == null) return false;
    final url = lib.catchupUrl(key: channel.key, start: p.start, stop: p.stop);
    if (url == null) return false;
    final item = ItemInfo(
      key: 'catchup:${channel.key}:${p.start}',
      kind: ItemKind.movie,
      name: '${channel.name} · ${p.title}',
      category: channel.category,
      logo: channel.logo,
      number: channel.number,
      archiveDays: 0,
    );
    if (nowPlaying.value?.key == item.key) return true;
    nowPlaying.value = item;
    _playingKey = channel.key;
    final choice = lib.bufferFor(key: channel.key);
    bufferRaisedTo.value = null;
    await adapter.play(
      ({required hls}) => url,
      live: false,
      preset: choice.preset,
      customSeconds: choice.seconds,
      adaptive: false,
      preferHls: false,
      extraOptions: const [],
    );
    return true;
  }

  /// iOS Picture-in-Picture: mpv stops (one provider connection), AVPlayer takes the same stream in PiP; when PiP
  /// ends, mpv resumes the same item. Live channels go as .m3u8 (AVPlayer can't play raw TS).
  Future<void> startApplePip() async {
    final item = nowPlaying.value;
    final lib = library;
    if (item == null || lib == null) return;
    final url = lib.streamUrl(
      key: item.key,
      preferHls: item.kind == ItemKind.live,
    );
    await _adapter?.stop();
    await _player?.stop();
    platform.onApplePipEnded = (_) => _resume(item);
    if (!await platform.startApplePip(url)) await _resume(item);
  }

  /// Plays [item] again even though it is still nowPlaying (after Apple PiP handed the stream back).
  Future<void> _resume(ItemInfo item) async {
    final lib = library;
    if (lib == null || nowPlaying.value?.key != item.key) {
      return; // stopped or replaced meanwhile
    }
    await _start(item, lib);
  }

  /// Opens [item] with its buffer (own override, else the profile's preset), measured bitrate, adaptive mode, and for
  /// live channels the timeshift back buffer (pause/rewind) from settings.
  Future<void> _start(ItemInfo item, Library lib) async {
    final live = item.kind == ItemKind.live;
    final choice = lib.bufferFor(key: item.key);
    final bitrate = lib.bitrate(key: item.key).toInt();
    final shift =
        int.tryParse(lib.setting(key: settingTimeshift) ?? '') ??
        defaultTimeshiftSeconds(desktop: isDesktop);
    bufferRaisedTo.value = null;
    await adapter.play(
      ({required hls}) => lib.streamUrl(key: item.key, preferHls: hls),
      live: live,
      preset: choice.preset,
      customSeconds: choice.seconds,
      bitrate: bitrate > 0 ? bitrate : null,
      adaptive: lib.setting(key: settingAdaptive) == '1',
      preferHls: live && lib.preferHls(key: item.key),
      extraOptions: live && shift > 0
          ? timeshiftOptions(
              windowSeconds: shift,
              bitrateBps: bitrate > 0 ? BigInt.from(bitrate) : null,
              // The back buffer's disk budget: a quarter of this. A free-space query per platform is a follow-up.
              freeDiskBytes: BigInt.from(isDesktop ? 16000000000 : 4000000000),
              cacheDir: await _timeshiftDir(),
            )
          : const [],
    );
  }

  Future<String> _timeshiftDir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/timeshift');
    await dir.create(recursive: true);
    return dir.path;
  }

  /// The only way playback ends besides starting another stream.
  Future<void> stopPlayback() async {
    _playingKey = null;
    nowPlaying.value = null;
    unawaited(platform.setPlaying(null));
    await _adapter?.stop();
    await _player?.stop();
  }

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }
}

/// Profile setting keys (the core's library.rs constants).
const settingBuffer = 'buffer_preset';
const settingAdaptive = 'adaptive_buffer';
const settingTimeshift = 'timeshift_secs';

/// True on iPhone/iPad (Apple Picture-in-Picture hand-over).
bool get isApple => !kIsWeb && Platform.isIOS;

/// True on desktop platforms (window-sized layouts, keyboard first).
bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);
