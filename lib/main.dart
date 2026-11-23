import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'brand.dart';

// ======================= MODELS =======================

enum Mode { sound, silent, off }

class UserText {
  String title;
  String body;
  UserText(this.title, this.body);

  Map<String, dynamic> toJson() => {'t': title, 'b': body};
  factory UserText.fromJson(Map<String, dynamic> j) =>
      UserText((j['t'] ?? '').toString(), (j['b'] ?? '').toString());
}

class Prayer {
  final int id;
  final String am;
  final String en;
  final String reason;
  final String verse;
  int minutes; // minutes since midnight
  Mode mode;
  final List<UserText> texts = []; // prayers/psalms added by the user
  String? soundUri; // Android: chosen ringtone (null = default alarm sound)
  String soundName = 'Default alarm sound';
  String winSound = 'alarm1'; // Windows: preset sound name

  Prayer(this.id, this.am, this.en, this.minutes, this.reason, this.verse,
      {this.mode = Mode.sound});

  int get hour => minutes ~/ 60;
  int get minute => minutes % 60;

  String get clock24 =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  // Ethiopian clock: 6:00 AM (or PM) = 12:00
  String get ethClock {
    var h = (hour - 6) % 12;
    if (h == 0) h = 12;
    return '$h:${minute.toString().padLeft(2, '0')}';
  }
}

class NextPrayer {
  final Prayer prayer;
  final DateTime at;
  NextPrayer(this.prayer, this.at);
}

List<Prayer> defaultPrayers() => [
      Prayer(
        1,
        'ነግኅ',
        'Neguh (Dawn)',
        6 * 60,
        'ሌሊቱን በሰላም ላሳለፈን አምላክ ምስጋና ለማቅረብ፣ አዳም የተፈጠረበት እና ጌታችን በጲላጦስ ፊት የቆመበት ሰዓት ነው።',
        '«አቤቱ፥ በማለዳ ድምፄን ትሰማለህ፥ በማለዳ በፊትህ እቆማለሁ እጠብቃለሁም።» (መዝ 5፥3)',
      ),
      Prayer(
        2,
        'ሠለስት',
        'Third hour',
        9 * 60,
        'መንፈስ ቅዱስ ለሐዋርያት የወረደበት፣ ጌታችን በጲላጦስ ፊት የተገረፈበት እና ቅዱስ ገብርኤል እመቤታችንን ያበሠረበት ሰዓት ነው።',
        '«እነዚህም ሦስት ሰዓት ሆኖአልና እናንተ እንደምታስቡት የሰከሩ አይደሉም።» (ሐዋ 2፥15)',
      ),
      Prayer(
        3,
        'ቀትር',
        'Sixth hour (Noon)',
        12 * 60,
        'ጌታችን መድኃኒታችን ኢየሱስ ክርስቶስ በቀራንዮ በመስቀል ላይ የተሰቀለበት እና ፀሐይ የጨለመችበት ሰዓት ነው።',
        '«ከስድስት ሰዓትም ጀምሮ እስከ ዘጠኝ ሰዓት ድረስ በምድር ሁሉ ላይ ጨለማ ሆነ።» (ማቴ 27፥45)',
      ),
      Prayer(
        4,
        'ተሰዓት',
        'Ninth hour',
        15 * 60,
        'ጌታችን በመስቀል ላይ ሆኖ ቅድስት ነፍሱን ከሥጋው የለየበት እና ሐዋርያት ለጸሎት ወደ መቅደስ የሚወጡበት ሰዓት ነው።',
        '«ጴጥሮስና ዮሐንስም በዘጠኝ ሰዓት በጸሎት ጊዜ ወደ መቅደስ ይወጡ ነበር።» (ሐዋ 3፥1)',
      ),
      Prayer(
        5,
        'ሠርክ',
        'Eleventh hour (Evening)',
        17 * 60,
        'ዮሴፍና ኒቆዲሞስ የጌታችንን ሥጋ ከመስቀል አውርደው የቀበሩበት እና ቀኑን በሰላም ላዋለን አምላክ ምስጋና የሚቀርብበት ነው።',
        '«ጸሎቴን በፊትህ እንደ ዕጣን ተቀበል፥ እጆቼንም ማንሣቴን እንደ ሠርክ መሥዋዕት።» (መዝ 140፥2)',
      ),
      Prayer(
        6,
        'ንዋም',
        'Niwam (Sleep)',
        21 * 60,
        'ጌታችን በጌቴሴማኒ የአትክልት ቦታ የጸለየበት፣ በሰላም እንድናድር ለመለመንና ንስሐ ለመግባት የሚጸለይበት ሰዓት ነው።',
        '«በአልጋዬም ላይ ሳለሁ አስብሃለሁ፥ በማለዳም እናገርልሃለሁ።» (መዝ 62፥6)',
      ),
      Prayer(
        7,
        'መንፈቀ ሌሊት',
        'Midnight',
        0,
        'ጌታችን የተወለደበት፣ ከሙታን የተነሣበት፣ ዳግም ለፍርድ የሚመጣበት እና ቅዱሳን በእስር ቤት ሆነው የዘመሩበት ሰዓት ነው።',
        '«በመንፈቀ ሌሊትም ጳውሎስና ሲላስ እየጸለዩ እግዚአብሔርን በዜማ ያመሰግኑ ነበር።» (ሐዋ 16፥25)',
      ),
    ];

// ======================= GLOBAL STATE =======================

final plugin = FlutterLocalNotificationsPlugin();
final navigatorKey = GlobalKey<NavigatorState>();
final List<Prayer> prayers = defaultPrayers();

// ---- Round 1: pre-alarm, mute, "prayed" check-in ----
int preAlarmMinutes = 0; // 0 = off, otherwise 5 / 10 / 15
DateTime? muteUntil; // null = not muted
final Set<int> doneToday = {}; // prayers marked as prayed (current Ethiopian day)
String _doneDay = '';

bool get isMuted => muteUntil != null && muteUntil!.isAfter(DateTime.now());

// The Ethiopian day starts at 6:00, so the midnight prayer belongs to the
// day that is ending, not the one that is starting.
String dayKeyFor(DateTime t) {
  final d = t.subtract(const Duration(hours: 6));
  return '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
}

// The most recent time this prayer's alarm rang (today or yesterday).
DateTime lastOccurrence(Prayer p) {
  final now = DateTime.now();
  var at = DateTime(now.year, now.month, now.day, p.hour, p.minute);
  if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
  return at;
}

Future<void> loadDone() async {
  _doneDay = dayKeyFor(DateTime.now()); // set first so timers don't re-trigger
  final sp = await SharedPreferences.getInstance();
  doneToday
    ..clear()
    ..addAll((sp.getStringList('done_$_doneDay') ?? <String>[])
        .map(int.parse));
  // keep only today's and yesterday's records - nothing is kept as history
  final yesterday = dayKeyFor(DateTime.now().subtract(const Duration(days: 1)));
  for (final k in sp.getKeys().toList()) {
    if (k.startsWith('done_') && k != 'done_$_doneDay' && k != 'done_$yesterday') {
      await sp.remove(k);
    }
  }
}

Future<void> setPrayed(Prayer p, bool value, {DateTime? occurrence}) async {
  final sp = await SharedPreferences.getInstance();
  final key = dayKeyFor(occurrence ?? DateTime.now());
  final list = (sp.getStringList('done_$key') ?? <String>[]).toSet();
  if (value) {
    list.add('${p.id}');
  } else {
    list.remove('${p.id}');
  }
  await sp.setStringList('done_$key', list.toList());
  if (key == _doneDay) {
    if (value) {
      doneToday.add(p.id);
    } else {
      doneToday.remove(p.id);
    }
  }
}

Future<void> saveSettings() async {
  final sp = await SharedPreferences.getInstance();
  await sp.setInt('pre', preAlarmMinutes);
  if (muteUntil == null) {
    await sp.remove('mute');
  } else {
    await sp.setInt('mute', muteUntil!.millisecondsSinceEpoch);
  }
}

Future<void> setPreAlarm(int minutes) async {
  preAlarmMinutes = minutes;
  await saveSettings();
  await rescheduleAll();
}

Future<void> setMuteUntil(DateTime? until) async {
  muteUntil = until;
  await saveSettings();
  await rescheduleAll();
}

Future<void> loadPrayers() async {
  final sp = await SharedPreferences.getInstance();
  for (final p in prayers) {
    p.minutes = sp.getInt('t${p.id}') ?? p.minutes;
    p.mode = Mode.values[sp.getInt('m${p.id}') ?? Mode.sound.index];
    p.soundUri = sp.getString('s${p.id}');
    p.soundName = sp.getString('sn${p.id}') ?? p.soundName;
    p.winSound = sp.getString('w${p.id}') ?? p.winSound;
    final raw = sp.getString('x${p.id}');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        p.texts
          ..clear()
          ..addAll(list
              .map((e) => UserText.fromJson(Map<String, dynamic>.from(e))));
      } catch (_) {}
    }
  }
  preAlarmMinutes = sp.getInt('pre') ?? 0;
  final mu = sp.getInt('mute');
  muteUntil = mu == null ? null : DateTime.fromMillisecondsSinceEpoch(mu);
  if (muteUntil != null && !muteUntil!.isAfter(DateTime.now())) {
    muteUntil = null;
    await sp.remove('mute');
  }
  await loadDone();
}

Future<void> savePrayer(Prayer p) async {
  final sp = await SharedPreferences.getInstance();
  await sp.setInt('t${p.id}', p.minutes);
  await sp.setInt('m${p.id}', p.mode.index);
  if (p.soundUri == null) {
    await sp.remove('s${p.id}');
  } else {
    await sp.setString('s${p.id}', p.soundUri!);
  }
  await sp.setString('sn${p.id}', p.soundName);
  await sp.setString('w${p.id}', p.winSound);
  await sp.setString(
      'x${p.id}', jsonEncode(p.texts.map((t) => t.toJson()).toList()));
  if (Platform.isAndroid) await scheduleAndroid(p, clearSnooze: true);
}

NextPrayer? findNext() {
  final now = DateTime.now();
  Prayer? best;
  DateTime? bestAt;
  for (final p in prayers) {
    if (p.mode == Mode.off) continue;
    var at = DateTime(now.year, now.month, now.day, p.hour, p.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    if (bestAt == null || at.isBefore(bestAt)) {
      best = p;
      bestAt = at;
    }
  }
  if (best == null || bestAt == null) return null;
  return NextPrayer(best, bestAt);
}

DateTime? prevPrayerTime() {
  final now = DateTime.now();
  DateTime? best;
  for (final p in prayers) {
    if (p.mode == Mode.off) continue;
    var at = DateTime(now.year, now.month, now.day, p.hour, p.minute);
    if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
    if (best == null || at.isAfter(best)) best = at;
  }
  return best;
}

// ======================= NOTIFICATIONS =======================

String bodyFor(Prayer p) => p.verse;

// The Dismiss button removes its own notification natively (cancelNotification
// is true). We must NOT call plugin.cancel() here: that would also cancel
// tomorrow's repeating alarm.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {}

// Ids: 1-7 prayer alarm | 101-107 snooze | 1100-1713 one-time alarms (mute window).
// Anything else (the pre-alarms) just opens the app.
int? alarmPrayerId(int id) {
  if (id >= 1 && id <= 7) return id;
  if (id >= 101 && id <= 107) return id - 100;
  if (id >= 1000 && id < 2000) return (id - 1000) ~/ 100;
  return null;
}

void onNotificationResponse(NotificationResponse r) {
  final id = r.id;
  if (id == null) return;
  if (r.actionId == 'dismiss') return;
  final pid = alarmPrayerId(id);
  if (pid == null) return;
  final match = prayers.where((e) => e.id == pid);
  if (match.isEmpty) return;
  navigatorKey.currentState?.push(MaterialPageRoute(
    builder: (_) => AlarmScreen(prayer: match.first, exitApp: false),
  ));
}

const kDefaultAlarmUri = 'content://settings/system/alarm_alert';
const _ringtoneChannel = MethodChannel('prayer/ringtone');

int _stableHash(String s) {
  var h = 7;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

// Opens Android's own ringtone picker (phone ringtones, alarms, notifications).
Future<void> pickRingtone(Prayer p) async {
  try {
    final res = await _ringtoneChannel.invokeMethod<Map>(
        'pick', {'current': p.soundUri ?? kDefaultAlarmUri});
    if (res == null) return;
    p.soundUri = res['uri'] as String?;
    p.soundName = (res['title'] as String?) ?? 'Custom sound';
  } on PlatformException {
    // picker not available - keep the current sound
  }
}

NotificationDetails detailsFor(Prayer p, {bool muted = false}) {
  final sound = p.mode == Mode.sound && !muted;
  final uri = p.soundUri ?? kDefaultAlarmUri;
  return NotificationDetails(
    android: AndroidNotificationDetails(
      // Alarm and Silent behave the same (wake screen, full-screen page,
      // dismiss button). Silent only turns the sound and vibration off.
      // Channel settings can't change once created, so Silent has its own channel.
      // one channel per ringtone (Android fixes a channel's sound once created)
      muted
          ? 'prayer_muted_v1'
          : (sound ? 'prayer_alarm_${_stableHash(uri)}' : 'prayer_silent_v3'),
      muted
          ? 'Prayer (muted banner)'
          : (sound ? 'Prayer alarm · ${p.soundName}' : 'Prayer alarm (silent)'),
      channelDescription: 'Notifications for the seven daily prayer hours',
      importance: muted ? Importance.high : Importance.max,
      priority: muted ? Priority.high : Priority.max,
      playSound: sound,
      sound: sound ? UriAndroidNotificationSound(uri) : null,
      enableVibration: sound,
      category: muted
          ? AndroidNotificationCategory.reminder
          : AndroidNotificationCategory.alarm,
      fullScreenIntent: !muted, // a muted banner never wakes the screen
      audioAttributesUsage: muted
          ? AudioAttributesUsage.notification
          : AudioAttributesUsage.alarm,
      additionalFlags: sound ? Int32List.fromList(<int>[4]) : null, // repeat sound
      timeoutAfter: 120000,
      visibility: NotificationVisibility.public,
      styleInformation: BigTextStyleInformation(bodyFor(p)),
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'dismiss',
          '✕  Dismiss',
          cancelNotification: true,
        ),
      ],
    ),
    windows: WindowsNotificationDetails(
      audio: sound
          ? WindowsNotificationAudio.preset(
              sound: WindowsNotificationSound.values.firstWhere(
                  (v) => v.name == p.winSound,
                  orElse: () => WindowsNotificationSound.alarm1))
          : WindowsNotificationAudio.silent(),
    ),
  );
}

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  // Ethiopia has no daylight saving, UTC+3 all year.
  tz.setLocalLocation(tz.getLocation('Africa/Addis_Ababa'));

  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const windows = WindowsInitializationSettings(
    appName: 'Prayer Notifier',
    appUserModelId: 'com.rebitechs.prayernotifier',
    guid: 'a3f1c2d4-5b6e-4f70-8a91-b2c3d4e5f607',
  );
  await plugin.initialize(
    settings: const InitializationSettings(android: android, windows: windows),
    onDidReceiveNotificationResponse: onNotificationResponse,
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  if (Platform.isAndroid) {
    final a = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await a?.requestNotificationsPermission();
    await a?.requestExactAlarmsPermission();
    await a?.requestFullScreenIntentPermission();
  }
}

// ======================= SCHEDULING (Android) =======================
// Notification ids:
//   1-7        repeating daily prayer alarm       101-107    snooze (one-time)
//   201-207    repeating daily pre-alarm
//   1100-1713  one-time prayer alarms used while a mute window is active
//   2100-2713  one-time pre-alarms used while a mute window is active

const kRollingDays = 14;
int _rollBase(Prayer p) => 1000 + p.id * 100;
int _preRollBase(Prayer p) => 2000 + p.id * 100;

Future<AndroidScheduleMode> _scheduleMode() async {
  final a = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  final canExact = await a?.canScheduleExactNotifications() ?? false;
  // If "Alarms & reminders" was denied, fall back to an inexact alarm
  // (can be a few minutes late) instead of failing silently.
  return canExact
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;
}

// Ids of notifications that are on screen right now.
Future<Set<int>> _activeIds() async {
  try {
    final a = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final list = await a?.getActiveNotifications() ?? <ActiveNotification>[];
    return {
      for (final n in list)
        if (n.id != null) n.id!,
    };
  } catch (_) {
    return <int>{};
  }
}

NotificationDetails preDetailsFor(Prayer p) {
  final chime = p.mode == Mode.sound; // Alarm -> soft chime, Silent -> no sound
  return NotificationDetails(
    android: AndroidNotificationDetails(
      chime ? 'prayer_pre_chime_v1' : 'prayer_pre_silent_v1',
      chime ? 'Prayer reminder (soft chime)' : 'Prayer reminder (silent)',
      channelDescription: 'A gentle reminder shortly before a prayer time',
      importance: Importance.high,
      priority: Priority.high,
      playSound: chime,
      enableVibration: false,
      category: AndroidNotificationCategory.reminder,
      timeoutAfter: preAlarmMinutes * 60 * 1000, // goes away at prayer time
      visibility: NotificationVisibility.public,
    ),
    windows: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
  );
}

String _preBody(Prayer p) =>
    'Prayer time in $preAlarmMinutes minutes · ${p.en} (${p.clock24})';

Future<void> _clearItem(int id, int rollBase, Set<int> active) async {
  await plugin.cancel(id: id);
  for (var k = 0; k < kRollingDays; k++) {
    if (!active.contains(rollBase + k)) await plugin.cancel(id: rollBase + k);
  }
}

// Schedules one daily item (a prayer alarm or its pre-alarm).
Future<void> _scheduleItem({
  required int id,
  required int rollBase,
  required int hour,
  required int minute,
  required String title,
  required String body,
  required NotificationDetails normal,
  NotificationDetails? muted, // null = skip the ones inside a mute window
  required AndroidScheduleMode mode,
  required Set<int> active,
}) async {
  final now = tz.TZDateTime.now(tz.local);
  var first =
      tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
  if (!first.isAfter(now)) first = first.add(const Duration(days: 1));

  final until = isMuted ? muteUntil : null;
  final affected = until != null && first.isBefore(until);

  try {
    if (!affected) {
      // Normal case: ONE repeating daily alarm. Scheduling again with the same
      // id replaces it and leaves a notification that is on screen alone.
      for (var k = 0; k < kRollingDays; k++) {
        if (!active.contains(rollBase + k)) {
          await plugin.cancel(id: rollBase + k);
        }
      }
      await plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: first,
        notificationDetails: normal,
        androidScheduleMode: mode,
        matchDateTimeComponents: DateTimeComponents.time, // repeat daily
      );
    } else {
      // Android cannot delay a repeating alarm, so while a mute window is
      // active we use one-time alarms for the next days. The normal repeating
      // alarm is put back the next time the app opens (or the mute ends).
      final u = until!;
      await plugin.cancel(id: id);
      for (var k = 0; k < kRollingDays; k++) {
        final at = first.add(Duration(days: k));
        final details = at.isBefore(u) ? muted : normal;
        if (details == null) continue;
        await plugin.zonedSchedule(
          id: rollBase + k,
          title: title,
          body: body,
          scheduledDate: at,
          notificationDetails: details,
          androidScheduleMode: mode,
        );
      }
    }
  } catch (e) {
    debugPrint('Could not schedule $title: $e');
  }
}

Future<void> scheduleAndroid(Prayer p,
    {bool clearSnooze = false, Set<int>? active}) async {
  if (clearSnooze) await plugin.cancel(id: p.id + 100); // pending snooze
  final act = active ?? await _activeIds();

  if (p.mode == Mode.off) {
    await _clearItem(p.id, _rollBase(p), act);
    await _clearItem(p.id + 200, _preRollBase(p), act);
    return;
  }

  final mode = await _scheduleMode();
  await _scheduleItem(
    id: p.id,
    rollBase: _rollBase(p),
    hour: p.hour,
    minute: p.minute,
    title: p.am,
    body: bodyFor(p),
    normal: detailsFor(p),
    muted: detailsFor(p, muted: true),
    mode: mode,
    active: act,
  );

  if (preAlarmMinutes > 0) {
    final m = (p.minutes - preAlarmMinutes) % 1440; // 00:00 prayer -> 23:5x
    await _scheduleItem(
      id: p.id + 200,
      rollBase: _preRollBase(p),
      hour: m ~/ 60,
      minute: m % 60,
      title: p.am,
      body: _preBody(p),
      normal: preDetailsFor(p),
      muted: null,
      mode: mode,
      active: act,
    );
  } else {
    await _clearItem(p.id + 200, _preRollBase(p), act);
  }
}

Future<void> rescheduleAll() async {
  if (!Platform.isAndroid) return;
  final active = await _activeIds();
  for (final p in prayers) {
    await scheduleAndroid(p, active: active);
  }
}

// Removes the notification that is ringing/showing for this prayer, but keeps
// tomorrow's alarm (cancelling a repeating id also cancels its next alarm).
Future<void> dismissShown(Prayer p) async {
  if (!Platform.isAndroid) return;
  final active = await _activeIds();
  var hitRepeating = false;
  for (final id in active) {
    if (alarmPrayerId(id) != p.id) continue;
    await plugin.cancel(id: id);
    if (id == p.id) hitRepeating = true;
  }
  if (hitRepeating) await scheduleAndroid(p); // put tomorrow's alarm back
}

// Snooze: one-time repeat of the alarm in 5 minutes (Android only).
Future<void> snoozePrayer(Prayer p) async {
  if (!Platform.isAndroid) return;
  await dismissShown(p);
  await plugin.cancel(id: p.id + 100);
  final when = tz.TZDateTime.now(tz.local).add(const Duration(minutes: 5));
  final u = isMuted ? muteUntil : null;
  final muted = u != null && when.isBefore(u);
  try {
    await plugin.zonedSchedule(
      id: p.id + 100,
      title: p.am,
      body: bodyFor(p),
      scheduledDate: when,
      notificationDetails: detailsFor(p, muted: muted),
      androidScheduleMode: await _scheduleMode(),
    );
  } catch (e) {
    debugPrint('Could not schedule snooze: $e');
  }
}

Future<void> showNow(Prayer p, {bool muted = false}) async {
  await plugin.show(
    id: p.id,
    title: p.am,
    body: bodyFor(p),
    notificationDetails: detailsFor(p, muted: muted),
  );
}

Future<void> showPre(Prayer p) async {
  await plugin.show(
    id: p.id + 200,
    title: p.am,
    body: _preBody(p),
    notificationDetails: preDetailsFor(p),
  );
}

// ======================= MAIN =======================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadPrayers();
  await initNotifications();

  // Was the app opened by the full-screen alarm notification?
  int? launchPrayerId;
  if (Platform.isAndroid) {
    final d = await plugin.getNotificationAppLaunchDetails();
    if (d?.didNotificationLaunchApp ?? false) {
      final nid = d?.notificationResponse?.id;
      launchPrayerId = nid == null ? null : alarmPrayerId(nid);
    }
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true); // lets us clean up the tray on close
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(480, 820),
        center: true,
        title: 'Prayer Notifier',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(App(launchPrayerId: launchPrayerId));
}

ThemeData buildTheme() {
  final scheme =
      ColorScheme.fromSeed(seedColor: const Color(0xFF2C5240)).copyWith(
    primary: const Color(0xFF1F4A38),
    onPrimary: const Color(0xFFF7F5EE),
    secondaryContainer: const Color(0xFFDDE8DF),
    onSecondaryContainer: const Color(0xFF14281F),
    surface: const Color(0xFFF7F5EE),
    onSurface: const Color(0xFF1B3A2C),
    outlineVariant: const Color(0xFFD9DED4),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF7F5EE),
  );
}

class App extends StatelessWidget {
  final int? launchPrayerId;
  const App({super.key, this.launchPrayerId});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Prayer Notifier',
        navigatorKey: navigatorKey,
        theme: buildTheme(),
        // Skip the splash when the app was opened by a prayer alarm.
        home: launchPrayerId != null
            ? Home(launchPrayerId: launchPrayerId)
            : const SplashScreen(next: Home()),
      );
}

// ======================= LOGO + SPLASH =======================

class PrayerLogo extends StatelessWidget {
  final double size;
  const PrayerLogo({super.key, this.size = 160});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  static const _angles = [0.0, 40.0, 80.0, 125.0, -40.0, -80.0, -125.0];
  static const _gold = Color(0xFFC8AA6A);

  static Path _cross() {
    final path = Path()
      ..addRect(const Rect.fromLTWH(96, 68, 8, 68))
      ..addRect(const Rect.fromLTWH(72, 88, 56, 8));
    void clover(Offset e, Offset d) {
      final q = Offset(-d.dy, d.dx);
      path.addOval(Rect.fromCircle(center: e + d * 1.0, radius: 5.5));
      path.addOval(Rect.fromCircle(center: e + q * 5.2 - d * 2.0, radius: 4));
      path.addOval(Rect.fromCircle(center: e - q * 5.2 - d * 2.0, radius: 4));
    }

    clover(const Offset(100, 68), const Offset(0, -1));
    clover(const Offset(100, 136), const Offset(0, 1));
    clover(const Offset(72, 92), const Offset(-1, 0));
    clover(const Offset(128, 92), const Offset(1, 0));
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 200;
    canvas.save();
    canvas.scale(k, k);

    // gold rim + green body
    canvas.drawCircle(
        const Offset(100, 100), 97, Paint()..color = const Color(0xFFB99A5B));
    canvas.drawCircle(
      const Offset(100, 100),
      93,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.08),
          radius: 1.0,
          colors: [Color(0xFF33614A), Color(0xFF14281F)],
        ).createShader(const Rect.fromLTWH(7, 7, 186, 186)),
    );
    canvas.drawCircle(
      const Offset(100, 100),
      72,
      Paint()
        ..color = _gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    final points = [
      for (final deg in _angles)
        Offset(100 + 54 * math.sin(deg * math.pi / 180),
            100 - 54 * math.cos(deg * math.pi / 180)),
    ];

    // gold rays pointing at the cross
    const c = Offset(100, 94);
    final rayPaint = Paint()..color = _gold;
    for (final p in points) {
      final v = c - p;
      final u = v / v.distance;
      final n = Offset(-u.dy, u.dx);
      final b = p + u * 10.0;
      final a1 = b + n * 4.2;
      final a2 = b - n * 4.2;
      canvas.drawPath(
        Path()
          ..moveTo(a1.dx, a1.dy)
          ..lineTo(a2.dx, a2.dy)
          ..lineTo(c.dx, c.dy)
          ..close(),
        rayPaint,
      );
    }

    // cross with a soft green halo
    final cross = _cross();
    final halo = Paint()..color = const Color(0xFF3F7058);
    canvas.drawPath(cross, halo);
    canvas.drawPath(
      cross,
      Paint()
        ..color = const Color(0xFF3F7058)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(cross, Paint()..color = _gold);

    // seven lamps
    final flame = Path()
      ..moveTo(0, -11)
      ..cubicTo(3.4, -6.5, 3.6, -2.5, 0, 0.2)
      ..cubicTo(-3.6, -2.5, -3.4, -6.5, 0, -11)
      ..close();
    final core = Path()
      ..moveTo(0, -6.5)
      ..cubicTo(1.4, -4, 1.4, -2, 0, -0.8)
      ..cubicTo(-1.4, -2, -1.4, -4, 0, -6.5)
      ..close();
    final bowl = Path()
      ..moveTo(-6.5, 0.8)
      ..quadraticBezierTo(0, 9.5, 6.5, 0.8)
      ..close();
    for (final p in points) {
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.drawCircle(
          const Offset(0, -4), 9, Paint()..color = const Color(0x38FFB24A));
      canvas.drawPath(bowl, Paint()..color = const Color(0xFFC98A3C));
      canvas.drawPath(flame, Paint()..color = const Color(0xFFFFC766));
      canvas.drawPath(core, Paint()..color = const Color(0xFFFFF0C0));
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SplashScreen extends StatefulWidget {
  final Widget next;
  const SplashScreen({super.key, required this.next});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..forward();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, __, ___) => widget.next,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ));
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    final scale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5EE),
      bottomNavigationBar: FadeTransition(
        opacity: fade,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('from',
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 2,
                        color: Color(0xFF5B6B60))),
                SizedBox(height: 6),
                RebiLogo(height: 32),
              ],
            ),
          ),
        ),
      ),
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                PrayerLogo(size: 176),
                SizedBox(height: 28),
                Text('ሰባቱ ጊዜ ጸሎት',
                    style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B3A2C))),
                SizedBox(height: 8),
                Text('PRAYER NOTIFIER',
                    style: TextStyle(
                        fontSize: 13,
                        letterSpacing: 3.5,
                        color: Color(0xFF5B6B60))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= SHARED CARDS =======================

class InfoCard extends StatelessWidget {
  final String label;
  final String text;
  final bool quote;
  final bool dark;
  final Widget? footer;
  const InfoCard({
    super.key,
    required this.label,
    required this.text,
    this.quote = false,
    this.dark = false,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF16291F) : Colors.white;
    final border = dark ? const Color(0xFF2E4A3C) : const Color(0xFFDDE3DA);
    final labelColor =
        dark ? const Color(0xFFD8B96E) : const Color(0xFF1F4A38);
    final textColor =
        dark ? const Color(0xFFF7F5EE) : const Color(0xFF1B3A2C);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: labelColor)),
          const SizedBox(height: 6),
          Text(text,
              style: TextStyle(
                  fontSize: quote ? 18 : 15,
                  height: 1.55,
                  fontStyle: quote ? FontStyle.italic : FontStyle.normal,
                  color: textColor)),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}

// ======================= ALARM SCREEN =======================

class AlarmScreen extends StatelessWidget {
  final Prayer prayer;
  final bool exitApp;
  const AlarmScreen({super.key, required this.prayer, required this.exitApp});

  Future<void> _close(BuildContext context) async {
    if (exitApp) {
      SystemNavigator.pop();
    } else if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _dismiss(BuildContext context) async {
    await dismissShown(prayer);
    if (context.mounted) await _close(context);
  }

  Future<void> _snooze(BuildContext context) async {
    await snoozePrayer(prayer);
    if (context.mounted) await _close(context);
  }

  // "Prayed" - quietly remembers it for today, then closes the alarm.
  Future<void> _prayed(BuildContext context) async {
    await setPrayed(prayer, true, occurrence: lastOccurrence(prayer));
    await dismissShown(prayer);
    if (context.mounted) await _close(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1F18),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            children: [
              // small logo with the prayer name beside it
              Row(
                children: [
                  const PrayerLogo(size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(prayer.am,
                            style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                        Text('${prayer.en} · ${prayer.clock24}',
                            style: const TextStyle(
                                fontSize: 14, color: Colors.white70)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // wide cards: verse, reason, and the user's own prayers
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InfoCard(
                          label: 'ጥቅስ · Verse',
                          text: prayer.verse,
                          quote: true,
                          dark: true),
                      InfoCard(
                          label: 'ምክንያት · Reason',
                          text: prayer.reason,
                          dark: true),
                      for (final t in prayer.texts)
                        InfoCard(
                            label: t.title.isNotEmpty
                                ? t.title
                                : 'ጸሎት / መዝሙር',
                            text: t.body,
                            dark: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // snooze, prayed, and a small X
              Row(
                children: [
                  if (Platform.isAndroid) ...[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF4E6B5C)),
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: const StadiumBorder(),
                        ),
                        onPressed: () => _snooze(context),
                        child: const Text('Snooze 5 min'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFC8AA6A),
                        foregroundColor: const Color(0xFF14281F),
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () => _prayed(context),
                      child: const Text('Prayed ✓',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    tooltip: 'Dismiss',
                    onPressed: () => _dismiss(context),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFC2392F),
                      foregroundColor: Colors.white,
                      fixedSize: const Size(56, 56),
                    ),
                    icon: const Icon(Icons.close, size: 28),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= PRAYER DETAIL =======================

class PrayerDetailScreen extends StatefulWidget {
  final Prayer prayer;
  const PrayerDetailScreen({super.key, required this.prayer});

  @override
  State<PrayerDetailScreen> createState() => _PrayerDetailScreenState();
}

class _PrayerDetailScreenState extends State<PrayerDetailScreen> {
  Prayer get p => widget.prayer;

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: p.hour, minute: p.minute),
    );
    if (t == null) return;
    setState(() => p.minutes = t.hour * 60 + t.minute);
    savePrayer(p);
  }

  Future<void> _editText({int? index}) async {
    final existing = index == null ? null : p.texts[index];
    final title = TextEditingController(text: existing?.title ?? '');
    final body = TextEditingController(text: existing?.body ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(index == null ? 'ጸሎት / መዝሙር ጨምር' : 'አስተካክል · Edit'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration:
                    const InputDecoration(labelText: 'ርዕስ (አማራጭ) · Title'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: body,
                minLines: 4,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'ጽሑፍ · Text',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (ok != true || body.text.trim().isEmpty) return;
    setState(() {
      final t = UserText(title.text.trim(), body.text.trim());
      if (index == null) {
        p.texts.add(t);
      } else {
        p.texts[index] = t;
      }
    });
    savePrayer(p);
  }

  void _useForAll() {
    for (final o in prayers) {
      o.soundUri = p.soundUri;
      o.soundName = p.soundName;
      savePrayer(o);
    }
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sound applied to all prayers')));
  }

  Future<void> _deleteText(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(p.texts[index].title.isNotEmpty
            ? p.texts[index].title
            : 'Delete this text?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => p.texts.removeAt(index));
    savePrayer(p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F5EE),
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            Text(p.am, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(p.en,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // time
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFDDE3DA)),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.clock24,
                              style: const TextStyle(
                                  fontSize: 32, fontWeight: FontWeight.w600)),
                          Text('ሰዓት ${p.ethClock} · every day',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    OutlinedButton(
                        onPressed: _pickTime,
                        child: const Text('Change time')),
                  ],
                ),
              ),
              // mode
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<Mode>(
                  segments: const [
                    ButtonSegment(
                        value: Mode.sound,
                        icon: Icon(Icons.alarm),
                        label: Text('Alarm')),
                    ButtonSegment(
                        value: Mode.silent,
                        icon: Icon(Icons.notifications_none),
                        label: Text('Silent')),
                    ButtonSegment(
                        value: Mode.off,
                        icon: Icon(Icons.notifications_off),
                        label: Text('Off')),
                  ],
                  selected: {p.mode},
                  onSelectionChanged: (s) {
                    setState(() => p.mode = s.first);
                    savePrayer(p);
                  },
                ),
              ),
              const SizedBox(height: 10),
              // ringtone for this prayer
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFDDE3DA)),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ድምፅ · Alarm sound',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1F4A38))),
                    const SizedBox(height: 8),
                    if (Platform.isAndroid)
                      Row(
                        children: [
                          const Icon(Icons.music_note, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(p.soundName)),
                          OutlinedButton(
                            onPressed: () async {
                              await pickRingtone(p);
                              if (!mounted) return;
                              setState(() {});
                              savePrayer(p);
                            },
                            child: const Text('Choose'),
                          ),
                        ],
                      )
                    else if (Platform.isWindows)
                      DropdownButton<String>(
                        isExpanded: true,
                        value: p.winSound,
                        items: [
                          for (final v in WindowsNotificationSound.values)
                            DropdownMenuItem(value: v.name, child: Text(v.name)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => p.winSound = v);
                          savePrayer(p);
                        },
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Test'),
                          onPressed: () => showNow(p),
                        ),
                        if (Platform.isAndroid)
                          TextButton(
                            onPressed: _useForAll,
                            child: const Text('Use for all prayers'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // verse + reason cards
              InfoCard(label: 'ጥቅስ · Verse', text: p.verse, quote: true),
              InfoCard(label: 'ምክንያት · Reason', text: p.reason),
              // user's own prayers and psalms
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text('ጸሎቶች እና መዝሙራት (${p.texts.length})',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1F4A38))),
              ),
              if (p.texts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                      'Add the short prayers or psalms read at this hour.'),
                ),
              for (var i = 0; i < p.texts.length; i++)
                InfoCard(
                  label: p.texts[i].title.isNotEmpty
                      ? p.texts[i].title
                      : 'ጸሎት / መዝሙር',
                  text: p.texts[i].body,
                  footer: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit, size: 20),
                        onPressed: () => _editText(index: i),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _deleteText(i),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.add),
                  label: const Text('ጸሎት / መዝሙር ጨምር · Add'),
                  onPressed: () => _editText(),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= ABOUT =======================

const kAppVersion = '1.0.0';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Widget _contact(BuildContext context, IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.copy, size: 18),
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label copied')));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF5B6B60);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F5EE),
        surfaceTintColor: Colors.transparent,
        title: const Text('About'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Center(child: PrayerLogo(size: 96)),
              const SizedBox(height: 14),
              const Text('ሰባቱ ጊዜ ጸሎት',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Prayer Notifier · version $kAppVersion',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted)),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 20),
              const Text('Made by',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, letterSpacing: 2, color: muted)),
              const SizedBox(height: 10),
              const Center(child: RebiLogo(height: 64)),
              const SizedBox(height: 12),
              const Text(kBrandTagline,
                  textAlign: TextAlign.center, style: TextStyle(color: muted)),
              const SizedBox(height: 16),
              if (kBrandWebsite.isNotEmpty)
                _contact(context, Icons.language, 'Website', kBrandWebsite),
              if (kBrandTelegram.isNotEmpty)
                _contact(context, Icons.send, 'Telegram', kBrandTelegram),
              if (kBrandEmail.isNotEmpty)
                _contact(context, Icons.email_outlined, 'Email', kBrandEmail),
              const SizedBox(height: 20),
              const Text('© 2026 $kBrandName. All rights reserved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: muted)),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= HOME SCREEN =======================

class Home extends StatefulWidget {
  final int? launchPrayerId;
  const Home({super.key, this.launchPrayerId});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WindowListener, TrayListener {
  Timer? _timer;
  final _firedToday = <String>{};

  @override
  void initState() {
    super.initState();

    rescheduleAll(); // Android: (re)register every alarm and pre-alarm
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }

    // One timer: live countdown on every platform + Windows notifications.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (Platform.isWindows) _tick();
      // a new Ethiopian day (06:00) clears the "prayed" dots
      if (dayKeyFor(DateTime.now()) != _doneDay) loadDone();
      // a finished mute window: go back to the normal repeating alarms
      if (muteUntil != null && !isMuted) {
        muteUntil = null;
        saveSettings();
        rescheduleAll();
      }
      if (mounted) setState(() {});
    });

    final id = widget.launchPrayerId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final m = prayers.where((e) => e.id == id);
        if (m.isNotEmpty) {
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (_) => AlarmScreen(prayer: m.first, exitApp: true),
          ));
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  // ---------- Windows tray ----------
  Future<void> _initTray() async {
    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await trayManager.setToolTip('Prayer Notifier');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Open Prayer Notifier'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: 'Exit'),
    ]));
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      _showWindow();
    } else if (menuItem.key == 'exit') {
      _exitApp();
    }
  }

  // Minimize button: hide to the tray (removed from the taskbar), keep running.
  @override
  void onWindowMinimize() async {
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }

  // X button: close the app completely.
  @override
  void onWindowClose() {
    _exitApp();
  }

  // ---------- Windows notification check ----------
  void _tick() {
    final n = DateTime.now();
    final day = '${n.year}-${n.month}-${n.day}';
    final nowMin = n.hour * 60 + n.minute;
    for (final p in prayers) {
      if (p.mode == Mode.off) continue;
      if (preAlarmMinutes > 0 && !isMuted) {
        final pm = (p.minutes - preAlarmMinutes) % 1440;
        if (nowMin == pm && _firedToday.add('pre-${p.id}-$day-$pm')) {
          showPre(p);
        }
      }
      final key = '${p.id}-$day-${p.minutes}';
      if (n.hour == p.hour && n.minute == p.minute && _firedToday.add(key)) {
        showNow(p, muted: isMuted);
      }
    }
  }

  // ---------- UI ----------
  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  double _progress(NextPrayer n) {
    final prev = prevPrayerTime();
    if (prev == null) return 0;
    final total = n.at.difference(prev).inSeconds;
    if (total <= 0) return 0;
    return (DateTime.now().difference(prev).inSeconds / total)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Widget _nextCard(NextPrayer? next, ColorScheme scheme) {
    if (next == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('All prayers are turned off'),
        ),
      );
    }
    final left = next.at.difference(DateTime.now());
    return Card(
      color: scheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('ቀጣይ ጸሎት · Next prayer',
                style: TextStyle(color: const Color(0xFFE3B25E))),
            const SizedBox(height: 4),
            Text(next.prayer.am,
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimary)),
            Text(next.prayer.en, style: TextStyle(color: scheme.onPrimary)),
            const SizedBox(height: 8),
            Text(_fmt(left),
                style: TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onPrimary)),
            Text('${next.prayer.clock24} · ሰዓት ${next.prayer.ethClock}',
                style: TextStyle(color: scheme.onPrimary.withOpacity(0.8))),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _progress(next),
                minHeight: 6,
                backgroundColor: const Color(0xFF3E6B57),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFE3B25E)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // Seven quiet dots for today. No streaks, no counts, nothing for past days.
  Widget _dots() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('ዛሬ',
              style: TextStyle(fontSize: 12, color: Color(0xFF5B6B60))),
          const SizedBox(width: 6),
          for (final p in prayers)
            Semantics(
              button: true,
              label:
                  '${p.en}: ${doneToday.contains(p.id) ? 'prayed' : 'not marked'}',
              child: InkResponse(
                radius: 22,
                onTap: () async {
                  await setPrayed(p, !doneToday.contains(p.id));
                  if (mounted) setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: doneToday.contains(p.id)
                          ? const Color(0xFFC8AA6A)
                          : Colors.transparent,
                      border: Border.all(
                        color: doneToday.contains(p.id)
                            ? const Color(0xFFC8AA6A)
                            : const Color(0xFF9AA79F),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controls() {
    final muted = isMuted;
    return Column(
      children: [
        if (muted)
          Container(
            margin: const EdgeInsets.only(top: 2, bottom: 4),
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF1E6C9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.volume_off,
                    size: 20, color: Color(0xFF5C4A18)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Silent until ${_hhmm(muteUntil!)} · quiet banners only',
                    style: const TextStyle(color: Color(0xFF5C4A18)),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await setMuteUntil(null);
                    if (mounted) setState(() {});
                  },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ActionChip(
              avatar: const Icon(Icons.volume_off, size: 18),
              label: Text(muted ? 'Change mute' : 'Mute…'),
              onPressed: _muteSheet,
            ),
            ActionChip(
              avatar: const Icon(Icons.timer_outlined, size: 18),
              label: Text(preAlarmMinutes == 0
                  ? 'Pre-alert: off'
                  : 'Pre-alert: $preAlarmMinutes min'),
              onPressed: _preSheet,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _muteSheet() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Silence prayers',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  'Prayers still appear as quiet banners: no sound, no vibration, no screen wake. Normal alarms return by themselves.'),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('1 hour'),
              onTap: () => Navigator.pop(c, 60),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('2 hours'),
              onTap: () => Navigator.pop(c, 120),
            ),
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: const Text('Rest of today (until midnight)'),
              onTap: () => Navigator.pop(c, -1),
            ),
            if (isMuted)
              ListTile(
                leading: const Icon(Icons.volume_up),
                title: const Text('Turn mute off'),
                onTap: () => Navigator.pop(c, 0),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final now = DateTime.now();
    DateTime? until;
    if (choice == -1) {
      until = DateTime(now.year, now.month, now.day + 1);
    } else if (choice > 0) {
      until = now.add(Duration(minutes: choice));
    }
    await setMuteUntil(until);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(until == null
          ? 'Mute is off'
          : 'Silent until ${_hhmm(until)}'),
    ));
  }

  Future<void> _preSheet() async {
    final v = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Gentle reminder before each prayer'),
        children: [
          for (final m in const [0, 5, 10, 15])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, m),
              child: Row(
                children: [
                  Expanded(
                      child: Text(m == 0 ? 'Off' : '$m minutes before')),
                  if (m == preAlarmMinutes) const Icon(Icons.check, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (v == null) return;
    await setPreAlarm(v);
    if (mounted) setState(() {});
  }

  Widget _prayerCard(Prayer p, bool isNext, ColorScheme scheme) {
    Color chipBg;
    Color chipFg;
    String chipLabel;
    switch (p.mode) {
      case Mode.sound:
        chipBg = const Color(0xFFDDE8DF);
        chipFg = const Color(0xFF1F4A38);
        chipLabel = 'Alarm';
        break;
      case Mode.silent:
        chipBg = const Color(0xFFF1E6C9);
        chipFg = const Color(0xFF5C4A18);
        chipLabel = 'Silent';
        break;
      case Mode.off:
        chipBg = const Color(0xFFE6E8E3);
        chipFg = const Color(0xFF4B5A50);
        chipLabel = 'Off';
        break;
    }
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: isNext ? Colors.white : const Color(0xFFFBFAF5),
      shape: isNext
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PrayerDetailScreen(prayer: p),
          ));
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.am, style: Theme.of(context).textTheme.titleLarge),
                    Text(p.en, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              if (isNext)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.notifications_active, size: 20),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(p.clock24,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  Text('ሰዓት ${p.ethClock}',
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(chipLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: chipFg)),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final next = findNext();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F5EE),
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        actions: [
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutScreen())),
          ),
        ],
        title: Row(
          children: const [
            PrayerLogo(size: 32),
            SizedBox(width: 12),
            Flexible(
              child: Text('ሰባቱ ጊዜ ጸሎት',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _nextCard(next, scheme),
          _dots(),
          _controls(),
          const SizedBox(height: 4),
          for (final p in prayers)
            _prayerCard(p, next?.prayer.id == p.id, scheme),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Send test notification'),
            onPressed: () => showNow(prayers.first),
          ),
          if (Platform.isWindows)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Windows: Minimize hides the app to the system tray and keeps notifying you. Close (X) exits the app completely.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}