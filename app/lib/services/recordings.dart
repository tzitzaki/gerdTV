// Recordings (core: recorder.rs): planned from a programme's sheet or started by hand in the player, they run while
// gerdTV runs (desktop, also in the menu bar; Android with its background service; none on iOS). A timer here starts
// the due ones and notes the ended ones. Each takes a provider connection: with the account's limit reached, a notice
// comes a minute before (owner decision: the recording wins unless skipped), and at the start playback stops.
// Files: a folder the user chose (desktop: a path; Android: the system's folder picker, written through a descriptor),
// else a gerdTV folder (desktop: Movies/gerdTV; Android: the app's own storage, deleted on uninstall).
// Android while gerdTV is closed: an exact alarm shows a notification at the start, and a tap opens gerdTV, which then
// starts it (a hidden engine started by an alarm alone is left for a device check: owner decision for now).
// Debugging: a planned recording that didn't start: is the profile open, the stop time still ahead? `check()` runs
// every 20 s; the list shows each one's state and why it ended.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/platform_bridge.dart';
import '../src/rust/api/library.dart';
import 'session.dart';

/// Margins around a programme: guide times are rarely exact.
const recordingLead = Duration(minutes: 2);
const recordingLag = Duration(minutes: 10);

/// The app-wide setting with the chosen folder: a path, or (Android) a folder's tree URI.
const settingRecordingsFolder = 'recordings_folder';

/// Whether this platform records (owner decision: not iOS, which suspends apps in the background).
bool get canRecord => !kIsWeb && !Platform.isIOS;

/// "Tagesschau 2026-11-26 20.00.ts": a file name without characters some file systems refuse.
String recordingFileName(String title, DateTime start) {
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').trim();
  String two(int n) => n.toString().padLeft(2, '0');
  final when =
      '${start.year}-${two(start.month)}-${two(start.day)} ${two(start.hour)}.${two(start.minute)}';
  return '${safe.isEmpty ? 'gerdTV' : safe} $when.ts';
}

/// The connections a start would use against the account's limit (null: unknown, so no check).
bool needsConnection({
  required int? limit,
  required int running,
  required bool playing,
}) => limit != null && running + (playing ? 1 : 0) >= limit;

class Recordings extends ChangeNotifier {
  Recordings(this._session);
  final Session _session;
  Timer? _timer;

  /// A planned recording that will take the connection from what plays: (its title, its start), shown by the shell;
  /// [skip] keeps playing.
  final conflict = ValueNotifier<({int id, String title})?>(null);
  final Set<int> _skipped = {};
  int _running = 0;

  void startTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => check());
    unawaited(check());
  }

  List<RecordingInfo> list() {
    try {
      return _session.library?.recordings() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  int? get _limit {
    final lib = _session.library;
    return int.tryParse(lib?.setting(key: 'account_limit') ?? '') ??
        _session.profile?.maxConnections;
  }

  /// Plans a programme's recording (lead and lag added).
  Future<void> plan(ItemInfo channel, ProgrammeInfo p) async {
    final lib = _session.library;
    if (lib == null) return;
    final start = p.start - recordingLead.inSeconds;
    lib.scheduleRecording(
      itemKey: channel.key,
      title: p.title,
      start: start,
      stop: p.stop + recordingLag.inSeconds,
    );
    await _session.reminders?.recordingAlarm(
      DateTime.fromMillisecondsSinceEpoch(start * 1000),
      p.title,
    );
    notifyListeners();
    await check();
  }

  /// Records [channel] now, until the running programme's end plus the lag (2 h without a guide).
  Future<void> recordNow(ItemInfo channel) async {
    final lib = _session.library;
    if (lib == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final running = (await lib.nowNext(keys: [channel.key])).firstOrNull?.now;
    lib.scheduleRecording(
      itemKey: channel.key,
      title: running?.title ?? channel.name,
      start: now,
      stop: running == null
          ? now + 7200
          : running.stop + recordingLag.inSeconds,
    );
    notifyListeners();
    await check();
  }

  void skip(int id) {
    _skipped.add(id);
    conflict.value = null;
    unawaited(_session.library?.stopRecording(id: id));
    notifyListeners();
  }

  Future<void> stop(int id) async {
    await _session.library?.stopRecording(id: id);
    notifyListeners();
  }

  /// Forgets a recording and deletes its file.
  Future<void> delete(RecordingInfo r) async {
    await _session.library?.deleteRecording(id: r.id);
    if (r.file.startsWith('content://')) {
      await PlatformBridge.deleteDocument(r.file);
    } else if (r.file.isNotEmpty) {
      final f = File(r.file);
      if (f.existsSync()) await f.delete();
    }
    notifyListeners();
  }

  /// Starts the due recordings, warns a minute ahead of a conflict, notes the ended ones.
  Future<void> check() async {
    final lib = _session.library;
    if (lib == null || !canRecord) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ended = _running;
    try {
      _running = lib.checkRecordings();
    } catch (_) {}
    for (final r in list()) {
      if (r.state != 'scheduled' || r.stop <= now || _skipped.contains(r.id)) {
        continue;
      }
      final busy = needsConnection(
        limit: _limit,
        running: _running,
        playing: _session.nowPlaying.value != null,
      );
      if (r.start > now) {
        if (busy && r.start - now <= 60) {
          conflict.value = (id: r.id, title: r.title);
        }
        continue;
      }
      // Owner decision: the recording wins.
      if (busy) await _session.stopPlayback();
      if (conflict.value?.id == r.id) conflict.value = null;
      try {
        await _start(lib, r);
        _running++;
      } catch (e) {
        debugPrint('recording ${r.id}: $e');
      }
    }
    await PlatformBridge.setRecording(_running > 0 ? 'Recording' : null);
    if (ended != _running) notifyListeners();
  }

  Future<void> _start(Library lib, RecordingInfo r) async {
    final name = recordingFileName(
      r.title,
      DateTime.fromMillisecondsSinceEpoch(r.start * 1000),
    );
    final folder = await this.folder();
    if (folder.startsWith('content://')) {
      final doc = await PlatformBridge.createDocument(folder, name);
      await lib.startRecordingFd(id: r.id, fd: doc.fd, place: doc.uri);
    } else {
      await Directory(folder).create(recursive: true);
      await lib.startRecordingPath(id: r.id, path: '$folder/$name');
    }
  }

  /// Where recordings go: the chosen folder, else gerdTV's own.
  Future<String> folder() async {
    final dir = _session.appDir;
    final chosen = dir == null
        ? null
        : appSetting(dir: dir, key: settingRecordingsFolder);
    if (chosen != null && chosen.isNotEmpty) return chosen;
    if (Platform.isAndroid) {
      return (await getExternalStorageDirectory() ??
              await getApplicationDocumentsDirectory())
          .path;
    }
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/Movies/gerdTV';
  }

  void setFolder(String folder) {
    final dir = _session.appDir;
    if (dir != null) {
      setAppSetting(dir: dir, key: settingRecordingsFolder, value: folder);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
