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
import '../platform/engine.dart';
import '../platform/platform_bridge.dart';
import '../player/av_player.dart';
import '../player/floating.dart';
import '../player/frame_rate.dart';
import '../player/next_up.dart';
import '../player/picture.dart';
import '../player/switch_player.dart';
import '../player/track_prefs.dart';
import '../screens/app_logo.dart';
import '../player/watchdog_adapter.dart';
import '../src/rust/api/hls.dart';
import '../src/rust/api/library.dart';
import '../src/rust/api/playback.dart';
import '../src/rust/api/premiumize.dart';
import '../theme.dart';
import 'reminders.dart';
import 'media_card.dart';
import 'secrets.dart';
import 'tracking.dart';

/// `choosing`: more than one profile and none set to open by itself: the start picker shows.
enum SessionState { loading, needsSetup, choosing, ready }

class Session extends ChangeNotifier {
  Session({Secrets? secrets, this.appDir}) : secrets = secrets ?? Secrets() {
    // Every start and stop reaches the native side in one place: Android keeps its foreground service (playback
    // with the screen off). Floating on leaving is stricter: see [_updateFloating].
    nowPlaying.addListener(() {
      unawaited(platform.setPlaying(nowPlaying.value?.name));
      _updateFloating();
    });
    nowPlaying.addListener(
      () => userPaused.value = false,
    ); // a new stream plays
    _card = MediaCard(this);
    platform.pip.addListener(_updatePip);
    platform.onPipRestore = () => onPipRestore?.call();
  }

  late final MediaCard _card;

  /// Paused by the user, wherever: player, floating window, lock screen, menu bar (not a stall or a stream's start).
  final ValueNotifier<bool> userPaused = ValueNotifier(false);

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

  /// Bumped by [groupsChanged] only: an open group reloads its items (a sync leaves it as it is).
  final orderChanged = ValueNotifier<int>(0);

  /// A group was hidden or shown again, or the user's own groups, names or order changed: every list reloads (as after
  /// a sync).
  void groupsChanged() {
    generation++;
    orderChanged.value++;
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

  /// Bumped when an item is marked as watched or unmarked: the check marks rebuild.
  final watchedChanged = ValueNotifier<int>(0);
  Set<String> _watched = const {};
  Library? _watchedOf;

  /// The open profile's watched movies and episodes (read once per profile, then kept here).
  Set<String> get watched {
    final lib = library;
    if (lib != null && !identical(lib, _watchedOf)) {
      _watchedOf = lib;
      _watched = lib.watchedKeys().toSet();
    }
    return _watched;
  }

  void toggleWatched(ItemInfo item) {
    library?.setWatched(key: item.key, watched: !watched.contains(item.key));
    _reloadWatched();
  }

  void _reloadWatched() {
    _watchedOf = null;
    watchedChanged.value++;
  }

  /// The countdown to the next episode (the player shows it).
  late final nextUp = NextUp((item) => unawaited(play(item)));
  static const settingAutoplayNext = 'autoplay_next';

  /// The player ran to the end: an episode is followed by its next one, unless that is switched off.
  Future<void> _onCompleted(bool done) async {
    final it = nowPlaying.value;
    final lib = library;
    if (!done) {
      nextUp.cancel(); // sought back, or the next one opened
      return;
    }
    // A connection lost for good also ends the file: only a real end counts. That one is saved as played to its
    // length, so it is marked as watched (the core counts whole seconds; the last frame may be a few ms short).
    final ended = ranToTheEnd(player.state.position, player.state.duration);
    _saveProgress(ended: ended);
    if (it == null || lib == null || it.kind != ItemKind.episode || !ended) {
      return;
    }
    if (lib.setting(key: settingAutoplayNext) == '0') return;
    try {
      final next = await lib.nextEpisode(key: it.key);
      if (next != null && nowPlaying.value?.key == it.key) nextUp.start(next);
    } catch (e) {
      debugPrint('next episode: $e');
    }
  }

  /// True while the guide downloads and imports (Settings → Guide shows it; lists keep their old now/next).
  bool guideRefreshing = false;
  bool _guideAgain = false;

  /// Bumped after each guide import so now/next and the grid reload.
  int guideGeneration = 0;

  /// Checks hourly whether a guide source is due (the app may stay open for days).
  Timer? _guideTimer;

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

  /// mpv's own player, for tests that set or read mpv properties ([player] may be AVPlayer's front).
  @visibleForTesting
  Player get mpvPlayer => _mpv;

  // Live channels on iOS and macOS: AVPlayer over the core's local HLS (owner decision; lib/player/av_player.dart).
  AvPlatformPlayer? _av;
  Player? _avPlayer;
  VideoController? _avVideo;
  LocalHlsStream? _hls;
  Timer? _hlsPoll;
  Timer? _avProgress;
  StreamSubscription<String>? _avErrors;

  /// Channels AVPlayer couldn't play this run (a codec it lacks): they play in mpv.
  final Set<String> _avFailed = {};

  /// True while AVPlayer plays (the player and the now-playing bar show its picture then).
  final ValueNotifier<bool> onAvPlayer = ValueNotifier(false);

  /// Live channels play in AVPlayer on Apple platforms when Settings → Playback says so (gerdTV's player by
  /// default). Read once, at start: a change applies after closing and reopening gerdTV.
  bool get _avForLive =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) &&
      appDir != null &&
      runningPlayers.live == LivePlayer.apple;

  /// The players this run uses, as stored when it started (Settings changes apply to the next one).
  late final ({PlayerEngine engine, LivePlayer live}) runningPlayers = (
    engine: readEngine(appDir!),
    live: readLivePlayer(appDir!),
  );

  AvPlatformPlayer get _avEngine {
    if (_av == null) {
      _av = AvPlatformPlayer();
      _avPlayer = Player(platformPlayer: _av);
      _avErrors = _av!.stream.error.listen(_onAvError);
      _av!.pip.addListener(_updatePip);
      _av!.onPipRestore = () => onPipRestore?.call();
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

  /// The live channel played before the current (or last) one: the player's "last channel". A movie in between or
  /// Stop doesn't change it.
  ItemInfo? lastChannel;
  ItemInfo? _channel;

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

  /// How much of the picture shows through the player's banner, in percent (app-wide, Settings → Appearance).
  final overlayTranslucency = ValueNotifier(defaultOverlayTranslucency);
  static const settingOverlayTranslucency = 'overlay_translucency';

  /// White on black at 40 % stays readable (5.7:1) even over a white picture; the slider ends at [maxOverlayTranslucency].
  static const defaultOverlayTranslucency = 40, maxOverlayTranslucency = 80;

  /// The stored value; anything unknown is the default.
  static int parseOverlayTranslucency(String? v) =>
      (int.tryParse(v ?? '') ?? defaultOverlayTranslucency).clamp(
        0,
        maxOverlayTranslucency,
      );

  Future<void> setOverlayTranslucency(int percent) async {
    overlayTranslucency.value = percent;
    setAppSetting(
      dir: await _dir(),
      key: settingOverlayTranslucency,
      value: '$percent',
    );
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
    runningPlayers; // captured now, before Settings can change them
    logo = parseAppLogo(appSetting(dir: dir, key: settingAppLogo));
    theme.value = ThemePrefs.parse(
      mode: appSetting(dir: dir, key: settingThemeMode),
      accent: appSetting(dir: dir, key: settingThemeAccent),
      tinted: appSetting(dir: dir, key: settingThemeTinted),
      black: appSetting(dir: dir, key: settingThemeBlack),
    );
    overlayTranslucency.value = parseOverlayTranslucency(
      appSetting(dir: dir, key: settingOverlayTranslucency),
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
    lastChannel = _channel = null;
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

  /// Changes what the open profile's provider sees as the player ("" = the default). Reopens the profile, because its
  /// connections carry the old one, which ends what plays.
  Future<void> setUserAgent(String value) async {
    final p = profile!;
    final saved = await saveProfile(
      dir: await _dir(),
      profile: ProfileInfo(
        id: p.id,
        name: p.name,
        source: p.source,
        server: p.server,
        userAgent: value,
        maxConnections: p.maxConnections,
      ),
    );
    profiles = [for (final q in profiles) q.id == saved.id ? saved : q];
    await openProfile(saved);
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
      tmdbKey = await secrets.readService(_appSecrets, 'tmdb');
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

  /// Refreshes the guide sources that are missing or too old (12 h; 6 h for a few; or all, always, with [force]: "Refresh now").
  /// Failures are kept per source (Settings → Guide shows them); the previous guide stays meanwhile.
  Future<void> refreshGuide({bool force = false}) async {
    final lib = library;
    _guideTimer ??= Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(refreshGuide()),
    );
    if (lib == null) return;
    if (guideRefreshing) {
      // A source added meanwhile isn't in the running refresh: once more afterwards, else it waits up to 12 h.
      _guideAgain |= force;
      return;
    }
    if (!force && !await lib.guideDue()) return;
    guideRefreshing = true;
    notifyListeners();
    try {
      await lib.refreshGuide(daysAhead: guideDaysAhead, force: force);
      guideGeneration++;
    } catch (e) {
      debugPrint(
        'guide refresh: $e',
      ); // a database error; download errors are recorded per source instead
    } finally {
      guideRefreshing = false;
      notifyListeners();
    }
    if (_guideAgain) {
      _guideAgain = false;
      await refreshGuide(force: true);
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
    nextUp.cancel();
    _saveProgress(); // the one playing until now
    _track('stop');
    _progressTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => _saveProgress(),
    );
    if (item.kind == ItemKind.live && item.key != _channel?.key) {
      lastChannel = _channel;
      _channel = item;
    }
    lib.touchRecent(key: item.key);
    nowPlaying.value = item;
    _playingKey = item.key;
    _loadPictureFormat();
    await _start(item, lib);
    _track('start', item: item);
    unawaited(_matchFrameRate(item));
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
    userPaused.value = pause;
    _track(pause ? 'pause' : 'start');
    if (onAvPlayer.value) {
      // AVPlayer has no watchdog here: the core keeps its provider connection alive while paused.
      pause ? await player.pause() : await player.play();
    } else {
      pause ? await adapter.pause() : await adapter.resume();
    }
  }

  /// The user's own TMDB key (app-wide, not per provider), null when none is set: movie and series pages then show
  /// the panel's facts only.
  String? tmdbKey;

  Future<void> setTmdbKey(String? key) async {
    final k = key?.trim();
    await secrets.writeService(
      _appSecrets,
      'tmdb',
      k == null || k.isEmpty ? null : k,
    );
    tmdbKey = k == null || k.isEmpty ? null : k;
    notifyListeners();
  }

  /// The owner of app-wide secrets in secure storage (profile secrets carry the profile's id there).
  static const _appSecrets = 'app';

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
    await _useMpv();
    _mpvPip(true);
    nowPlaying.value = item;
    _playingKey = item.key;
    _loadPictureFormat();
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
      extraOptions: [..._trackOptions(lib), ...await _deinterlaceOptions(lib)],
    );
  }

  /// The profile's audio and subtitle languages, set (or put back) before each start.
  List<MpvOption> _trackOptions(Library? lib) {
    delays = TrackDelays();
    return trackOptions(
      audio: lib?.setting(key: settingAudioLanguage),
      subtitle: lib?.setting(key: settingSubtitleLanguage),
    );
  }

  int _displayMode = 0;

  /// Android TV, when switched on: the display's refresh rate follows the stream, once mpv knows its frame rate.
  Future<void> _matchFrameRate(ItemInfo item) async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        library?.setting(key: settingMatchFrameRate) != '1') {
      return;
    }
    final modes = await PlatformBridge.displayModes();
    if (modes.isEmpty) return;
    // Up to 30 s: a slow channel with a big buffer takes a while to its first frame.
    for (var i = 0; i < 60; i++) {
      if (nowPlaying.value?.key != item.key) return;
      final fps =
          double.tryParse(
            await (_mpv.platform as NativePlayer).getProperty('container-fps'),
          ) ??
          0;
      if (fps > 0 && player.state.position > Duration.zero) {
        final mode = displayModeFor(fps, modes, modes.first);
        if (mode != null) {
          _displayMode = mode.id;
          await platform.setDisplayMode(mode.id);
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Deinterlacing for the next start. Nothing is touched until it was on once; from then on, off restores the
  /// decoder the video controller chose (read before the first change).
  Future<List<MpvOption>> _deinterlaceOptions(Library? lib) async {
    final on = lib?.setting(key: settingDeinterlace) == '1';
    if (!on && _defaultHwdec == null) return const [];
    _defaultHwdec ??= await (mpvPlayer.platform as NativePlayer).getProperty(
      'hwdec',
    );
    return deinterlaceOptions(on: on, defaultHwdec: _defaultHwdec!);
  }

  String? _defaultHwdec;

  /// The running item's picture format (player/picture.dart), remembered per item.
  final pictureFormat = ValueNotifier(PictureFormat.fit);

  void _loadPictureFormat() => pictureFormat.value = PictureFormat.parse(
    library?.setting(key: PictureFormat.settingFor(_playingKey ?? '')),
  );

  void setPictureFormat(PictureFormat f) {
    final key = _playingKey;
    if (key == null) return;
    library?.setSetting(
      key: PictureFormat.settingFor(key),
      value: f == PictureFormat.fit ? '' : f.name,
    );
    pictureFormat.value = f;
  }

  /// The delays of what plays, as the track sheet shows them.
  TrackDelays delays = TrackDelays();

  /// Audio or subtitles later (positive) or earlier, in milliseconds, for what plays now; the next start is at 0 again.
  Future<void> setDelay({int? audioMs, int? subtitleMs}) async {
    if (audioMs != null) {
      await adapter.setProperty('audio-delay', '${audioMs / 1000}');
    }
    if (subtitleMs != null) {
      await adapter.setProperty('sub-delay', '${subtitleMs / 1000}');
    }
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
    _loadPictureFormat();
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
      extraOptions: [..._trackOptions(lib), ...await _deinterlaceOptions(lib)],
      userAgent: profile?.userAgent ?? '',
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

  /// True while Apple's floating window shows the stream, whichever engine plays: the app then shows no second one.
  final ValueNotifier<bool> floating = ValueNotifier(false);
  void _updatePip() =>
      floating.value = platform.pip.value || (_av?.pip.value ?? false);

  /// The floating window's restore button (main: reopens the player).
  void Function()? onPipRestore;

  Future<void> stopApplePip() =>
      onAvPlayer.value ? _avEngine.stopPip() : platform.stopApplePip();

  /// iOS, while mpv plays: its frames feed the PiP layer, and the PiP window's play/pause, skip and seek range follow
  /// the player (once a second).
  void _mpvPip(bool on) {
    _watchFloating();
    if (!isApple) return;
    _pipTimer?.cancel();
    _pipTimer = null;
    unawaited(platform.preparePip(on));
    if (!on) return;
    platform.onPipCommand ??= (action, secs) {
      switch (action) {
        case 'play':
          unawaited(userPause(false));
        case 'pause':
          unawaited(userPause(true));
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

  /// Leaving the app floats the picture only while something really plays (lib/player/floating.dart): evaluated on
  /// every player event, sent to the native side of the engine that plays when it changed.
  void _updateFloating() {
    final st = _front?.state; // none before the first stream
    final on =
        st != null &&
        floatsOnLeave(
          selected: nowPlaying.value != null,
          playing: st.playing,
          completed: st.completed,
          position: st.position,
          failed: _adapter?.failure.value != null,
        );
    final next = (mpv: on && !onAvPlayer.value, av: on && onAvPlayer.value);
    if (next == _floating) return;
    final prev = _floating;
    _floating = next;
    if (next.mpv != prev.mpv) unawaited(platform.setFloating(next.mpv));
    if (next.av != prev.av) unawaited(_av?.setFloating(next.av));
  }

  ({bool mpv, bool av}) _floating = (mpv: false, av: false);
  List<StreamSubscription<Object?>>? _floatSubs;

  /// Follows the player from the first stream on (creating the player starts mpv, so not earlier).
  void _watchFloating() {
    if (_floatSubs != null) return;
    _card.watch();
    final s = player.stream;
    _floatSubs = [
      s.playing.listen((_) => _updateFloating()),
      s.completed.listen((done) {
        _updateFloating();
        unawaited(_onCompleted(done));
      }),
      s.position.listen((_) => _updateFloating()),
    ];
    adapter.failure.addListener(_updateFloating);
    onAvPlayer.addListener(_updateFloating);
  }

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
      userAgent: profile?.userAgent ?? '',
      start: switch (live ? null : lib.resumePosition(key: item.key)) {
        final secs? => Duration(seconds: secs),
        null => null,
      },
      extraOptions: [
        ..._trackOptions(lib),
        ...await _deinterlaceOptions(lib),
        if (live && shift > 0)
          ...timeshiftOptions(
            windowSeconds: shift,
            bitrateBps: bitrate > 0 ? BigInt.from(bitrate) : null,
            // The back buffer's disk budget: a quarter of this. A free-space query per platform is a follow-up.
            freeDiskBytes: BigInt.from(isDesktop ? 16000000000 : 4000000000),
            cacheDir: await _timeshiftDir(),
          ),
      ],
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
    final upstream = lib.streamUrl(key: item.key, preferHls: false);
    if (upstream.split('?').first.endsWith('.m3u8')) {
      url = upstream; // the provider sends HLS itself (M3U profiles)
    } else {
      try {
        // Returns once the playlist has its first segments (about 6 s at live pace).
        final hls = await lib.startLocalHls(
          key: item.key,
          cacheDir: (await getTemporaryDirectory()).path,
          windowSecs: shift,
          // The same disk budget as mpv's back buffer: a quarter of it.
          maxBytes: BigInt.from((isDesktop ? 16000000000 : 4000000000) ~/ 4),
        );
        if (nowPlaying.value?.key != item.key) {
          hls.stop(); // zapped or stopped meanwhile
          return;
        }
        _hls = hls;
        url = hls.url();
        window = shift;
      } catch (e) {
        // Refused or no data: mpv plays it, and its watchdog shows why.
        debugPrint('local HLS: $e; ${item.name} plays in mpv');
        _avFailed.add(item.key);
        // Stopped or zapped while it was starting: nothing plays in its place.
        if (nowPlaying.value?.key == item.key) await _start(item, lib);
        return;
      }
    }
    bufferRaisedTo.value = null;
    timeshiftWindow.value = window;
    _switch!.switchTo(av);
    onAvPlayer.value = true;
    adapter.target.value =
        choice.seconds; // the player's "Buffer x / target" readout
    await av.openUrl(
      url,
      bufferSecs: choice.seconds,
      userAgent: profile?.userAgent ?? '',
    );
    // The safety net: AVPlayer waits silently (no error) on a stream it can't decode. Not playing 15 s after the
    // start, unpaused, the channel goes to mpv for this run.
    final from = av.state.position;
    _avProgress = Timer(const Duration(seconds: 15), () {
      final st = av.state;
      if (onAvPlayer.value &&
          nowPlaying.value?.key == item.key &&
          st.playing &&
          st.position - from < const Duration(seconds: 1)) {
        _onAvError('no picture 15 s after the start');
      }
    });
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
    _avProgress?.cancel();
    _hlsPoll?.cancel();
    _hlsPoll = null;
    _hls?.stop();
    _hls = null;
    await _av?.stop();
    _adapter?.reconnecting.value = 0;
    _adapter?.failure.value = null;
  }

  /// The player's buffer button: the running stream's buffer, in whichever engine plays it.
  Future<void> applyBuffer(BufferPreset preset, int seconds) async {
    if (onAvPlayer.value) {
      adapter.target.value = seconds;
      await _avEngine.setBuffer(seconds);
    } else {
      await adapter.applyBuffer(preset, seconds);
    }
  }

  Future<String> _timeshiftDir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/timeshift');
    await dir.create(recursive: true);
    return dir.path;
  }

  Timer? _progressTimer;

  /// Continue watching: how far the playing movie or episode got (the core keeps it from 2 min, drops it at 95 %).
  /// Catch-up archives play as movies but aren't kept.
  void _saveProgress({bool ended = false}) {
    final it = nowPlaying.value;
    final lib = library;
    if (it == null ||
        lib == null ||
        !(it.kind == ItemKind.movie || it.kind == ItemKind.episode) ||
        it.key.startsWith('catchup:') ||
        it.key.startsWith('premiumize:')) {
      return;
    }
    final duration = player.state.duration.inSeconds;
    final pos = ended ? duration : player.state.position.inSeconds;
    if (pos <= 0) return;
    lib.saveProgress(key: it.key, position: pos, duration: duration);
    // The core marks it from 95 %; the check marks follow.
    if (!watched.contains(it.key) && lib.watchedKeys().contains(it.key)) {
      _reloadWatched();
    }
  }

  /// The only way playback ends besides starting another stream.
  Future<void> stopPlayback() async {
    nextUp.cancel();
    _saveProgress();
    _track('stop');
    _playingKey = null;
    if (_displayMode != 0) {
      _displayMode = 0;
      unawaited(platform.setDisplayMode(0));
    }
    nowPlaying.value = null;
    timeshiftWindow.value = 0;
    await _useMpv();
    _mpvPip(false);
    await _adapter?.stop();
    await _player?.stop();
  }

  @override
  void dispose() {
    _card.dispose();
    _progressTimer?.cancel();
    _pipTimer?.cancel();
    for (final s in _floatSubs ?? const <StreamSubscription<Object?>>[]) {
      unawaited(s.cancel());
    }
    _avProgress?.cancel();
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
