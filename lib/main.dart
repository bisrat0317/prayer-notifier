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
  if (Platform.isAndroid) await scheduleAndroid(p);
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

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  final id = response.id;
  if (id != null && response.actionId == 'dismiss') {
    FlutterLocalNotificationsPlugin().cancel(id: id);
  }
}

void onNotificationResponse(NotificationResponse r) {
  final id = r.id;
  if (id == null) return;
  if (r.actionId == 'dismiss') {
    plugin.cancel(id: id);
    return;
  }
  final pid = id > 100 ? id - 100 : id;
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

NotificationDetails detailsFor(Prayer p) {
  final sound = p.mode == Mode.sound;
  final uri = p.soundUri ?? kDefaultAlarmUri;
  return NotificationDetails(
    android: AndroidNotificationDetails(
      // Alarm and Silent behave the same (wake screen, full-screen page,
      // dismiss button). Silent only turns the sound and vibration off.
      // Channel settings can't change once created, so Silent has its own channel.
      // one channel per ringtone (Android fixes a channel's sound once created)
      sound ? 'prayer_alarm_${_stableHash(uri)}' : 'prayer_silent_v3',
      sound ? 'Prayer alarm · ${p.soundName}' : 'Prayer alarm (silent)',
      channelDescription: 'Notifications for the seven daily prayer hours',
      importance: Importance.max,
      priority: Priority.max,
      playSound: sound,
      sound: sound ? UriAndroidNotificationSound(uri) : null,
      enableVibration: sound,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
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

// Android: OS-level daily scheduled notification
Future<void> scheduleAndroid(Prayer p) async {
  await plugin.cancel(id: p.id);
  if (p.mode == Mode.off) return;

  final now = tz.TZDateTime.now(tz.local);
  var when = tz.TZDateTime(
      tz.local, now.year, now.month, now.day, p.hour, p.minute);
  if (when.isBefore(now)) when = when.add(const Duration(days: 1));

  await plugin.zonedSchedule(
    id: p.id,
    title: p.am,
    body: bodyFor(p),
    scheduledDate: when,
    notificationDetails: detailsFor(p),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time, // repeat daily
  );
}

// Snooze: one-time repeat of the alarm in 5 minutes (Android only).
Future<void> snoozePrayer(Prayer p) async {
  await plugin.cancel(id: p.id);
  if (!Platform.isAndroid) return;
  final when = tz.TZDateTime.now(tz.local).add(const Duration(minutes: 5));
  await plugin.zonedSchedule(
    id: p.id + 100,
    title: p.am,
    body: bodyFor(p),
    scheduledDate: when,
    notificationDetails: detailsFor(p),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
  );
}

Future<void> showNow(Prayer p) async {
  await plugin.show(
    id: p.id,
    title: p.am,
    body: bodyFor(p),
    notificationDetails: detailsFor(p),
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
      launchPrayerId = (nid != null && nid > 100) ? nid - 100 : nid;
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
    await plugin.cancel(id: prayer.id);
    if (context.mounted) await _close(context);
  }

  Future<void> _snooze(BuildContext context) async {
    await snoozePrayer(prayer);
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
              // snooze with a small X beside it
              Row(
                children: [
                  if (Platform.isAndroid) ...[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFF4E6B5C)),
                          minimumSize: const Size(0, 52),
                          shape: const StadiumBorder(),
                        ),
                        onPressed: () => _snooze(context),
                        child: const Text('Snooze 5 min'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ] else
                    const Spacer(),
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

    if (Platform.isAndroid) {
      for (final p in prayers) {
        scheduleAndroid(p);
      }
    }
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }

    // One timer: live countdown on every platform + Windows notifications.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (Platform.isWindows) _tick();
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
    for (final p in prayers) {
      if (p.mode == Mode.off) continue;
      final key = '${p.id}-$day-${p.minutes}';
      if (n.hour == p.hour && n.minute == p.minute && _firedToday.add(key)) {
        showNow(p);
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