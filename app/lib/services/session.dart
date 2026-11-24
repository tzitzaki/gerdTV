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

import '../platform/menu_bar.dart';
import '../platform/platform_bridge.dart';
import '../player/av_player.dart';
import '../player/switch_player.dart';
import '../screens/app_logo.dart';
import '../player/watchdog_adapter.dart';
import '../src/rust/api/hls.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
import '../src/rust/api/premiumize.dart';
import '../theme.dart';
import 'reminders.dart';
import 'secrets.dart';
import 'tracking.dart';

/// `choosing`: more than one profile and none set to open by itself: the start picker shows.
enum SessionState { loading, needsSetup, choosing, ready }

class Session extends ChangeNotifier {
  Session({Secrets? secrets, this.appDir}) : secrets = secrets ?? Secrets() {
    // Every start and stop reaches the native side in one place: Android keeps its foreground service (playback
    // with the screen off) and enters Picture-in-Picture on leaving only while something plays.
    nowPlaying.addListener(
      () => unawaited(platform.setPlaying(nowPlaying.value?.name)),
    );
  }

  final Secrets secrets;

  /// The app-support folder (profiles.json, profile databases). Set in tests; else from path_provider.
  String? appDir;

  SessionState state = SessionState.loading;
  ProfileInfo? profile;

  /// Every saved profile (one provider account each), for the start picker and Settings → Account.
  List<ProfileInfo> profiles = const [];

  /// App-wide settings (app.json): the profile opened last (the picker lists it first) and the one that opens without
  /// asking ("Always open this one"; empty: ask whenever there are several).
  static const settingLastProfile = 'last_profile';
  static const settingAlwaysProfile = 'always_profile';
  Library? library;

  /// True while a sync runs; the UI keeps showing the cached catalogue meanwhile.
  bool syncing = false;

  /// The last sync's outcome for the user (an error message, or null when fine).
  String? syncError;
  SyncSummary? lastSync;

  /// Bumped after each sync so lists reload.
  int generation = 0;

  /// Bumped when a favourite is added or removed: the stars and the Favourites group rebuild.
  final favouritesChanged = ValueNotifier<int>(0);
  Set<String> _favourites = const {};
  Library? _favouritesOf;

  /// The open profile's favourites (read once per profile, then kept here).
  Set<String> get favourites {
    final lib = library;
    if (lib != null && !identical(lib, _favouritesOf)) {
      _favouritesOf = lib;
      _favourites = lib.favouriteKeys().toSet();
    }
    return _favourites;
  }

  /// A group was hidden or shown again: every list reloads (as after a sync).
  void groupsChanged() {
    generation++;
    favouritesChanged.value++; // the Favourites group and continue watching may lose or regain items
    notifyListeners();
  }

  /// The star, a long press or a long OK: in or out of the favourites.
  void toggleFavourite(ItemInfo item) {
    final lib = library;
    if (lib == null) return;
    final on = !favourites.contains(item.key);
    lib.setFavourite(key: item.key, favourite: on);
    _favourites = on
        ? {...favourites, item.key}
        : ({...favourites}..remove(item.key));
    favouritesChanged.value++;
  }

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

  Player? _player; // mpv (media_kit), driven by the watchdog adapter
  VideoController? _video;
  WatchdogAdapter? _adapter;

  /// The player every screen listens to: it forwards whichever engine plays (lib/player/switch_player.dart).
  Player get player => _front ??= Player(
    platformPlayer: _switch = SwitchPlatformPlayer(_mpv.platform!),
  );
  Player? _front;
  SwitchPlatformPlayer? _switch;

  Player get _mpv => _player ??= _newPlayer();

  // Live channels on iOS and macOS: AVPlayer over the core's local HLS (owner decision; lib/player/av_player.dart).
  AvPlatformPlayer? _av;
  Player? _avPlayer;
  VideoController? _avVideo;
  LocalHlsStream? _hls;
  Timer? _hlsPoll;
  StreamSubscription<String>? _avErrors;

  /// Channels AVPlayer couldn't play this run (a codec it lacks): they play in mpv.
  final Set<String> _avFailed = {};

  /// True while AVPlayer plays (the player and the now-playing bar show its picture then).
  final ValueNotifier<bool> onAvPlayer = ValueNotifier(false);

  /// Live channels play in AVPlayer on Apple platforms.
  static bool get _avForLive =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  AvPlatformPlayer get _avEngine {
    if (_av == null) {
      _av = AvPlatformPlayer();
      _avPlayer = Player(platformPlayer: _av);
      _avErrors = _av!.stream.error.listen(_onAvError);
    }
    return _av!;
  }

  Player _newPlayer() {
    final p = Player(configuration: WatchdogAdapter.playerConfiguration);
    // iPhone/iPad: mpv's built-in "fast" profile (bilinear scaling, no dithering or HDR peak detection): less GPU
    // and battery for a slightly softer picture when scaled (owner decision). An mpv without the profile only logs.
    if (!kIsWeb && Platform.isIOS) {
      (p.platform as NativePlayer)
          .command(['apply-profile', 'fast'])
          .catchError((Object e) => debugPrint('apply-profile fast: $e'));
    }
    return p;
  }

  /// Software video rendering, only for CI: GitHub's macOS runners are VMs without a usable GPU, and the hardware
  /// texture stalled there (`just mac-check` sets GERDTV_SOFTWARE_VIDEO). Real devices use hardware rendering.
  static const _softwareVideo = bool.fromEnvironment('GERDTV_SOFTWARE_VIDEO');

  /// The picture of whichever engine plays.
  VideoController get video => onAvPlayer.value
      ? _avVideo ??= VideoController(_avPlayer!, create: avVideoController)
      : _video ??= VideoController(
          _mpv,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: !_softwareVideo,
          ),
        );
  WatchdogAdapter get adapter => _adapter ??= WatchdogAdapter(
    _mpv,
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

  /// Programme reminders (set by main(); null in tests without notifications).
  Reminders? reminders;

  /// The channels Up/Down switch through in the player: the group (or guide rows) the channel was opened from.
  List<ItemInfo> zapList = const [];

  /// What is playing right now, or null. Playback only ends by Stop or by starting another stream (owner decision):
  /// leaving the player screen keeps it running, shown by the now-playing bar in the shell.
  final ValueNotifier<ItemInfo?> nowPlaying = ValueNotifier(null);

  /// Adaptive mode raised the current channel's buffer to this many seconds (the player shows a short notice).
  final ValueNotifier<int?> bufferRaisedTo = ValueNotifier(null);

  /// The running stream's timeshift window in seconds (pause/rewind live); 0 for VOD, catch-up or timeshift off.
  final ValueNotifier<int> timeshiftWindow = ValueNotifier(0);

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

  /// The app's logo (app-wide setting, Settings → Appearance), shown in the shell and on the setup screen.
  AppLogo logo = AppLogo.screen;

  /// The app-wide setting that stores [logo] (gerdtv_core::library::set_app_setting, app.json).
  static const settingAppLogo = 'app_logo';

  /// Stores the logo and switches the launcher icon (Android, iOS) or the Dock/window icon (macOS, Linux).
  Future<void> setLogo(AppLogo l) async {
    setAppSetting(dir: await _dir(), key: settingAppLogo, value: l.name);
    logo = l;
    notifyListeners();
    await platform.setLogo(l);
  }

  /// The look (app-wide, Settings → Appearance → Theme): the app rebuilds its theme whenever it changes.
  final theme = ValueNotifier(const ThemePrefs());

  /// The app-wide settings that store [theme].
  static const settingThemeMode = 'theme_mode',
      settingThemeAccent = 'theme_accent',
      settingThemeTinted = 'theme_tinted',
      settingThemeBlack = 'theme_black';

  /// Stores and applies a new look at once.
  Future<void> setTheme(ThemePrefs t) async {
    final dir = await _dir();
    setAppSetting(dir: dir, key: settingThemeMode, value: t.mode.name);
    setAppSetting(dir: dir, key: settingThemeAccent, value: '${t.accent}');
    setAppSetting(dir: dir, key: settingThemeTinted, value: '${t.tinted}');
    setAppSetting(dir: dir, key: settingThemeBlack, value: '${t.black}');
    theme.value = t;
  }

  /// macOS: whether closing keeps gerdTV in the menu bar (Settings → Playback; app-wide).
  bool menuBar = true;

  Future<void> setMenuBar(bool on) async {
    setAppSetting(
      dir: await _dir(),
      key: settingMenuBar,
      value: on ? 'on' : 'off',
    );
    menuBar = on;
    await applyMenuBar(on);
  }

  /// Opens the first profile whose secrets are readable; otherwise asks for setup.
  Future<void> start() async {
    final dir = await _dir();
    logo = parseAppLogo(appSetting(dir: dir, key: settingAppLogo));
    theme.value = ThemePrefs.parse(
      mode: appSetting(dir: dir, key: settingThemeMode),
      accent: appSetting(dir: dir, key: settingThemeAccent),
      tinted: appSetting(dir: dir, key: settingThemeTinted),
      black: appSetting(dir: dir, key: settingThemeBlack),
    );
    menuBar = menuBarOn(appSetting(dir: dir, key: settingMenuBar));
    unawaited(applyMenuBar(menuBar));
    platform.onMenuBar = (action) async {
      if (action == 'stop') return stopPlayback();
      await userPause(player.state.playing);
    };
    // The launcher icons of Android and iOS stay switched; the Dock and window icons are set again on every start.
    if (Platform.isMacOS || Platform.isLinux) unawaited(platform.setLogo(logo));
    profiles = await listProfiles(dir: dir);
    await _openOrChoose();
  }

  /// One profile, or the one set to open always: open it. Several: the picker. None that opens: setup.
  Future<void> _openOrChoose() async {
    final dir = await _dir();
    final always = appSetting(dir: dir, key: settingAlwaysProfile);
    final pinned = profiles.where((p) => p.id == always).firstOrNull;
    if (pinned != null && await openProfile(pinned)) return;
    if (profiles.length > 1) {
      final last = appSetting(dir: dir, key: settingLastProfile);
      // The last one first: usually the one wanted.
      profiles = [
        ...profiles.where((p) => p.id == last),
        ...profiles.where((p) => p.id != last),
      ];
      state = SessionState.choosing;
      notifyListeners();
      return;
    }
    for (final p in profiles) {
      if (await openProfile(p)) return;
    }
    state = SessionState.needsSetup;
    notifyListeners();
  }

  /// Opens [p] (at start, from the picker, or switching in Settings): its cached catalogue at once, then a sync in
  /// the background. [always]: open it without asking from now on (true) or ask again (false). False when its
  /// secrets are missing (e.g. a new device with the profile list restored) or its database can't open.
  Future<bool> openProfile(ProfileInfo p, {bool? always}) async {
    final s = await secrets.read(p.id);
    if (s == null && p.source != SourceKind.m3UFile) return false;
    if (library != null) await stopPlayback();
    zapList = const [];
    if (!await _open(p, s ?? const [])) return false;
    final dir = await _dir();
    setAppSetting(dir: dir, key: settingLastProfile, value: p.id);
    if (always != null) {
      setAppSetting(
        dir: dir,
        key: settingAlwaysProfile,
        value: always ? p.id : '',
      );
    }
    generation++;
    unawaited(sync()); // cache first, then refresh in the background
    return true;
  }

  /// Whether [p] opens without asking.
  bool opensAlways(ProfileInfo p) =>
      appDir != null &&
      appSetting(dir: appDir!, key: settingAlwaysProfile) == p.id;

  Future<bool> _open(ProfileInfo p, List<String> s) async {
    try {
      library = await Library.open(
        dir: await _dir(),
        profileId: p.id,
        secrets: s,
      );
      profile = p;
      premiumizeToken = await secrets.readService(p.id, 'premiumize');
      await tracking.load(p.id);
      state = SessionState.ready;
      notifyListeners();
      unawaited(
        reminders?.watchLinux(library!),
      ); // Linux shows reminders itself while the app runs
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
    if (library != null) await stopPlayback(); // added from Settings: the old profile's stream ends
    library = lib;
    profile = saved;
    profiles = [...profiles, saved];
    setAppSetting(dir: dir, key: settingLastProfile, value: saved.id);
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
    // Only the links that exist: deleting a key that was never written crashed the app on Linux (libsecret,
    // flutter_secure_storage_linux 3.0.3), seen in the journey's "remove" step.
    if (premiumizeToken != null) {
      await secrets.writeService(p.id, 'premiumize', null);
    }
    premiumizeToken = null;
    await tracking.forget();
    library = null;
    profile = null;
    profiles = [...profiles.where((o) => o.id != p.id)];
    await _openOrChoose(); // another profile, the picker, or setup when it was the last
  }

  /// Plays an item through the watchdog. Live channels use the URL form that worked last time; movies and episodes
  /// continue where they were left.
  Future<void> play(ItemInfo item) async {
    final lib = library;
    if (lib == null) return;
    if (nowPlaying.value?.key == item.key) {
      return; // reopening the player for the running stream: keep it going
    }
    _saveProgress(); // the one playing until now
    _track('stop');
    _progressTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => _saveProgress(),
    );
    lib.touchRecent(key: item.key);
    nowPlaying.value = item;
    _playingKey = item.key;
    await _start(item, lib);
    _track('start', item: item);
  }

  /// Trakt and Simkl for the open profile (services/tracking.dart).
  late final tracking = Tracking(secrets);

  /// Tells Trakt and Simkl what the running movie or episode does ([action]: start, pause, stop), with how far it
  /// got; nothing for anything else.
  void _track(String action, {ItemInfo? item}) {
    final it = item ?? nowPlaying.value;
    final lib = library;
    if (it == null || lib == null) return;
    final dur = player.state.duration.inSeconds;
    final progress = dur > 0
        ? player.state.position.inSeconds * 100 / dur
        : 0.0;
    unawaited(tracking.scrobble(lib, it.key, action, progress.toDouble()));
  }

  /// A pause or resume by the user (the player's button or Space, the macOS menu bar): the watchdog's own pause,
  /// and the tracking services hear of it.
  Future<void> userPause(bool pause) async {
    _track(pause ? 'pause' : 'start');
    pause ? await adapter.pause() : await adapter.resume();
  }

  /// The open profile's Premiumize key or token (premiumize_screen.dart), null when not linked.
  String? premiumizeToken;

  /// Links Premiumize with an API key or a device-login token, after Premiumize accepted it (throws its reason).
  Future<void> linkPremiumize(String? token) async {
    final p = profile;
    if (p == null) return;
    if (token != null) await pmCheck(token: token.trim());
    await secrets.writeService(p.id, 'premiumize', token?.trim());
    premiumizeToken = token?.trim();
    notifyListeners();
  }

  /// Plays a file by its own URL (a Premiumize cloud file): like a recording, seekable, no progress kept.
  Future<void> playUrl(ItemInfo item, String url) async {
    final lib = library;
    if (lib == null || nowPlaying.value?.key == item.key) return;
    _saveProgress();
    nowPlaying.value = item;
    _playingKey = item.key;
    bufferRaisedTo.value = null;
    timeshiftWindow.value = 0;
    final choice = lib.bufferFor(key: item.key);
    await adapter.play(
      ({required hls}) => url,
      live: false,
      preset: choice.preset,
      customSeconds: choice.seconds,
      adaptive: false,
      preferHls: false,
      extraOptions: const [],
    );
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
      group: '',
    );
    if (nowPlaying.value?.key == item.key) return true;
    await _useMpv();
    _mpvPip(true);
    nowPlaying.value = item;
    _playingKey = channel.key;
    final choice = lib.bufferFor(key: channel.key);
    bufferRaisedTo.value = null;
    timeshiftWindow.value =
        0; // an archive plays like a recording: its own seek bar
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

  /// Why the last Picture-in-Picture didn't start (the player shows it once), null when it did.
  final pipFailure = ValueNotifier<String?>(null);

  /// Picture-in-Picture on Apple platforms: a live channel in AVPlayer floats as it is; on iOS, mpv's picture floats
  /// from its own frames (no hand-over, so nothing reconnects).
  Future<void> startApplePip() async {
    pipFailure.value = null;
    final started = onAvPlayer.value
        ? await _avEngine.startPip()
        : await platform.startApplePip();
    if (!started) {
      pipFailure.value = 'PiP: not possible right now';
    }
  }

  /// iOS, while mpv plays: its frames feed the PiP layer, and the PiP window's play/pause, skip and seek range follow
  /// the player (once a second).
  void _mpvPip(bool on) {
    if (!isApple) return;
    _pipTimer?.cancel();
    _pipTimer = null;
    unawaited(platform.preparePip(on));
    if (!on) return;
    platform.onPipCommand ??= (action, secs) {
      switch (action) {
        case 'play':
          unawaited(adapter.resume());
        case 'pause':
          unawaited(adapter.pause());
        case 'skip':
          unawaited(
            player.seek(
              player.state.position +
                  Duration(milliseconds: (secs * 1000).round()),
            ),
          );
      }
    };
    _pipTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final st = player.state;
      unawaited(
        platform.pipState(
          playing: st.playing,
          position: st.position.inMilliseconds / 1000,
          duration: st.duration.inMilliseconds / 1000,
          live: nowPlaying.value?.kind == ItemKind.live,
        ),
      );
    });
  }

  Timer? _pipTimer;

  /// Opens [item] with its buffer (own override, else the profile's preset), measured bitrate, adaptive mode, and for
  /// live channels the timeshift back buffer (pause/rewind) from settings.
  Future<void> _start(ItemInfo item, Library lib) async {
    final live = item.kind == ItemKind.live;
    if (live && _avForLive && !_avFailed.contains(item.key)) {
      await _startAv(item, lib);
      return;
    }
    await _useMpv();
    _mpvPip(true);
    final choice = lib.bufferFor(key: item.key);
    final bitrate = lib.bitrate(key: item.key).toInt();
    final shift =
        int.tryParse(lib.setting(key: settingTimeshift) ?? '') ??
        defaultTimeshiftSeconds(desktop: isDesktop);
    bufferRaisedTo.value = null;
    timeshiftWindow.value = live && shift > 0 ? shift : 0;
    await adapter.play(
      ({required hls}) => lib.streamUrl(key: item.key, preferHls: hls),
      live: live,
      preset: choice.preset,
      customSeconds: choice.seconds,
      bitrate: bitrate > 0 ? bitrate : null,
      adaptive: lib.setting(key: settingAdaptive) == '1',
      preferHls: live && lib.preferHls(key: item.key),
      start: switch (live ? null : lib.resumePosition(key: item.key)) {
        final secs? => Duration(seconds: secs),
        null => null,
      },
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

  /// A live channel in AVPlayer: the core reads the provider's stream into a local HLS with the timeshift window
  /// (one provider connection; drops and stalls are reconnected there, so AVPlayer only sees a discontinuity).
  /// A provider that sends HLS itself is played directly (rewinding only inside its own window).
  Future<void> _startAv(ItemInfo item, Library lib) async {
    _mpvPip(false);
    await _adapter?.stop();
    await _player?.stop();
    await _stopAv();
    final av = _avEngine;
    player; // the front player exists before it follows AVPlayer
    final choice = lib.bufferFor(key: item.key);
    final shift =
        int.tryParse(lib.setting(key: settingTimeshift) ?? '') ??
        defaultTimeshiftSeconds(desktop: isDesktop);
    String url;
    var window = 0;
    try {
      final hls = await lib.startLocalHls(
        key: item.key,
        cacheDir: (await getTemporaryDirectory()).path,
        windowSecs: shift,
        // The same disk budget as mpv's back buffer: a quarter of it.
        maxBytes: BigInt.from((isDesktop ? 16000000000 : 4000000000) ~/ 4),
      );
      _hls = hls;
      url = hls.url();
      window = shift;
    } catch (e) {
      debugPrint('local HLS: $e');
      url = lib.streamUrl(key: item.key, preferHls: false);
    }
    bufferRaisedTo.value = null;
    timeshiftWindow.value = window;
    _switch!.switchTo(av);
    onAvPlayer.value = true;
    await av.openUrl(url, bufferSecs: choice.seconds);
    // The core's view of the provider connection, shown like the watchdog's (reconnecting n, or why it stopped).
    _hlsPoll = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = _hls?.status();
      if (s == null) return;
      adapter.reconnecting.value = s.reconnecting ? s.reconnects : 0;
      adapter.failure.value = s.failure;
    });
  }

  /// AVPlayer couldn't play the channel: it plays in mpv from now on (one restart, never mid-way otherwise).
  void _onAvError(String message) {
    final item = nowPlaying.value;
    final lib = library;
    if (!onAvPlayer.value || item == null || lib == null) return;
    debugPrint('AVPlayer: $message; ${item.name} plays in mpv');
    _avFailed.add(item.key);
    unawaited(_start(item, lib));
  }

  /// mpv plays next: AVPlayer and its local HLS stop.
  Future<void> _useMpv() async {
    if (!onAvPlayer.value) return;
    await _stopAv();
    _switch?.switchTo(_mpv.platform!);
    onAvPlayer.value = false;
  }

  Future<void> _stopAv() async {
    _hlsPoll?.cancel();
    _hlsPoll = null;
    _hls?.stop();
    _hls = null;
    await _av?.stop();
    _adapter?.reconnecting.value = 0;
    _adapter?.failure.value = null;
  }

  /// The player's buffer button: the running stream's buffer, in whichever engine plays it.
  Future<void> applyBuffer(BufferPreset preset, int seconds) => onAvPlayer.value
      ? _avEngine.setBuffer(seconds)
      : adapter.applyBuffer(preset, seconds);

  Future<String> _timeshiftDir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/timeshift');
    await dir.create(recursive: true);
    return dir.path;
  }

  Timer? _progressTimer;

  /// Continue watching: how far the playing movie or episode got (the core keeps it from 2 min, drops it at 95 %).
  /// Catch-up archives play as movies but aren't kept.
  void _saveProgress() {
    final it = nowPlaying.value;
    final lib = library;
    if (it == null ||
        lib == null ||
        !(it.kind == ItemKind.movie || it.kind == ItemKind.episode) ||
        it.key.startsWith('catchup:') ||
        it.key.startsWith('premiumize:')) {
      return;
    }
    final pos = player.state.position.inSeconds;
    if (pos <= 0) return;
    lib.saveProgress(
      key: it.key,
      position: pos,
      duration: player.state.duration.inSeconds,
    );
  }

  /// The only way playback ends besides starting another stream.
  Future<void> stopPlayback() async {
    _saveProgress();
    _track('stop');
    _playingKey = null;
    nowPlaying.value = null;
    timeshiftWindow.value = 0;
    await _useMpv();
    _mpvPip(false);
    await _adapter?.stop();
    await _player?.stop();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _pipTimer?.cancel();
    _hlsPoll?.cancel();
    _hls?.stop();
    unawaited(_avErrors?.cancel());
    unawaited(_front?.dispose());
    unawaited(_avPlayer?.dispose());
    unawaited(_player?.dispose());
    super.dispose();
  }
}

/// Profile setting keys (the core's library.rs constants).
const settingBuffer = 'buffer_preset';
const settingAdaptive = 'adaptive_buffer';
const settingTimeshift = 'timeshift_secs';

/// True on iPhone/iPad (Apple Picture-in-Picture of mpv's picture).
bool get isApple => !kIsWeb && Platform.isIOS;

/// True on desktop platforms (window-sized layouts, keyboard first).
bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);
