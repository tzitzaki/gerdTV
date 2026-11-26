// Reminders for guide programmes (owner decision): stored by the core (user data, `reminders` table), shown as a
// system notification 5 minutes before the start (Android's inexact alarm can be a few minutes late, so there is
// a margin), scheduled in UTC (one moment; no time zone database needed). Linux has no scheduled notifications
// (flutter_local_notifications), so there the app itself watches the soonest reminder while it runs. A tap on the
// notification plays the channel. Debugging: a missing notification on Android 13+ usually means the permission
// was declined; the reminder itself is still in Settings' data.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../src/rust/api/library.dart';

class Reminders {
  Reminders({required this.onOpen});

  /// Plays the channel of a tapped reminder (by item key).
  final void Function(String itemKey) onOpen;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Timer? _linuxTimer;

  /// How long before the start the reminder shows.
  static const lead = Duration(minutes: 5);

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Reminders',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
  );

  /// A notification id that is the same in every run (String.hashCode is not): FNV-1a over channel and start.
  static int idFor(String itemKey, int start) {
    var h = 0x811c9dc5;
    for (final c in '$itemKey@$start'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Sets the plugin up; also plays a reminder that launched the app. Never throws (no notification service, e.g.
  /// headless test runs: reminders then stay in-app only).
  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Permission is asked when the first reminder is set, not at start.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Watch'),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload != null) onOpen(r.payload!);
        },
      );
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final key = launch?.notificationResponse?.payload;
      if (launch?.didNotificationLaunchApp == true && key != null) onOpen(key);
    } catch (e) {
      debugPrint('reminders: no notifications here ($e)');
    }
  }

  Future<void> _askPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, sound: true);
  }

  /// Sets or clears a reminder (stored by the core) and its notification.
  Future<void> set(
    Library lib,
    ReminderInfo r,
    String channelName,
    bool on,
  ) async {
    await lib.setReminder(
      reminder: r,
      on_: on,
    ); // `on` is a Dart keyword: the bridge calls it on_
    final id = idFor(r.itemKey, r.start);
    if (!_ready) return;
    if (!on) {
      await _plugin.cancel(id: id);
      return;
    }
    await _askPermission();
    if (!kIsWeb && Platform.isLinux) {
      await watchLinux(lib, {r.itemKey: channelName});
      return;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(r.start * 1000)
        .subtract(lead);
    // Starts within the lead time: nothing to schedule.
    if (at.isBefore(DateTime.now())) {
      return;
    }
    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: r.title,
      body: channelName,
      payload: r.itemKey,
    );
  }

  /// Android: a notification exactly at a recording's start, for when gerdTV is closed then; tapping it opens
  /// gerdTV, whose scheduler starts the recording (services/recordings.dart). Elsewhere the app records while it runs.
  Future<void> recordingAlarm(DateTime at, String title) async {
    if (kIsWeb ||
        !Platform.isAndroid ||
        !_ready ||
        at.isBefore(DateTime.now())) {
      return;
    }
    await _askPermission();
    await _plugin.zonedSchedule(
      id: idFor('recording:$title', at.millisecondsSinceEpoch ~/ 1000),
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: _details,
      // To the minute (USE_EXACT_ALARM in the manifest: gerdTV isn't in the Play Store, whose policy limits it).
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      title: title,
      body: 'Recording: open gerdTV to start it',
      payload: 'recording',
    );
  }

  /// Linux only: a timer for the soonest reminder while the app runs, which shows it then.
  Future<void> watchLinux(
    Library lib, [
    Map<String, String> names = const {},
  ]) async {
    if (kIsWeb || !Platform.isLinux || !_ready) return;
    _linuxTimer?.cancel();
    // Only reminders still to show (the core keeps one until an hour after its start).
    DateTime showAt(ReminderInfo r) =>
        DateTime.fromMillisecondsSinceEpoch(r.start * 1000).subtract(lead);
    final next = (await lib.reminders())
        .where((r) => showAt(r).isAfter(DateTime.now()))
        .firstOrNull;
    if (next == null) return;
    final at = showAt(next);
    _linuxTimer = Timer(at.difference(DateTime.now()), () async {
      final channel =
          names[next.itemKey] ??
          (await lib.item(key: next.itemKey))?.name ??
          '';
      await _plugin.show(
        id: idFor(next.itemKey, next.start),
        title: next.title,
        body: channel,
        notificationDetails: _details,
        payload: next.itemKey,
      );
      await watchLinux(lib);
    });
  }
}
