import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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

// ======================= NOTIFICATIONS =======================

String bodyFor(Prayer p) => p.verse;

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {}

void onNotificationResponse(NotificationResponse r) {
  final id = r.id;
  if (id == null) return;
  if (r.actionId == 'dismiss') {
    plugin.cancel(id: id);
    return;
  }
  final match = prayers.where((e) => e.id == id);
  if (match.isEmpty) return;
  navigatorKey.currentState?.push(MaterialPageRoute(
    builder: (_) => AlarmScreen(prayer: match.first, exitApp: false),
  ));
}

NotificationDetails detailsFor(Prayer p) {
  final sound = p.mode == Mode.sound;
  return NotificationDetails(
    android: AndroidNotificationDetails(
      // Alarm and Silent behave the same (wake screen, full-screen page,
      // dismiss button). Silent only turns the sound and vibration off.
      // Channel settings can't change once created, so Silent has its own channel.
      sound ? 'prayer_alarm_v2' : 'prayer_silent_v3',
      sound ? 'Prayer alarm' : 'Prayer alarm (silent)',
      channelDescription: 'Notifications for the seven daily prayer hours',
      importance: Importance.max,
      priority: Priority.max,
      playSound: sound,
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
              sound: WindowsNotificationSound.alarm1)
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
    appUserModelId: 'com.example.prayer_notifier',
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
      launchPrayerId = d?.notificationResponse?.id;
    }
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true); // X button hides to tray
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

class App extends StatelessWidget {
  final int? launchPrayerId;
  const App({super.key, this.launchPrayerId});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Prayer Notifier',
        navigatorKey: navigatorKey,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF7B3F00),
          useMaterial3: true,
        ),
        home: Home(launchPrayerId: launchPrayerId),
      );
}

// ======================= ALARM SCREEN =======================

class AlarmScreen extends StatelessWidget {
  final Prayer prayer;
  final bool exitApp;
  const AlarmScreen({super.key, required this.prayer, required this.exitApp});

  Future<void> _dismiss(BuildContext context) async {
    await plugin.cancel(id: prayer.id);
    if (exitApp) {
      SystemNavigator.pop();
    } else if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2B1600),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Icon(Icons.alarm, size: 64, color: Colors.amber),
              const SizedBox(height: 8),
              Text(prayer.am,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              Text('${prayer.en} · ${prayer.clock24}',
                  style: const TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(prayer.verse,
                          style: const TextStyle(
                              fontSize: 20,
                              fontStyle: FontStyle.italic,
                              color: Colors.white)),
                      const SizedBox(height: 16),
                      Text(prayer.reason,
                          style: const TextStyle(
                              fontSize: 15, color: Colors.white70)),
                      for (final t in prayer.texts) ...[
                        const SizedBox(height: 16),
                        if (t.title.isNotEmpty)
                          Text(t.title,
                              style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.amber)),
                        Text(t.body,
                            style: const TextStyle(
                                fontSize: 17, color: Colors.white)),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 88,
                height: 88,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => _dismiss(context),
                  child: const Icon(Icons.close, size: 48, color: Colors.white),
                ),
              ),
              const SizedBox(height: 6),
              const Text('Dismiss', style: TextStyle(color: Colors.white70)),
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

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit') {
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    final prevent = await windowManager.isPreventClose();
    if (prevent) await windowManager.hide(); // X = minimize to tray
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

  // ---------- Actions ----------
  Future<void> _pickTime(Prayer p) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: p.hour, minute: p.minute),
    );
    if (t == null) return;
    setState(() => p.minutes = t.hour * 60 + t.minute);
    savePrayer(p);
  }

  Future<void> _editText(Prayer p, {int? index}) async {
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

  Future<void> _deleteText(Prayer p, int index) async {
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

  // ---------- UI ----------
  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
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
                style: TextStyle(color: scheme.onPrimary.withOpacity(0.8))),
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
          ],
        ),
      ),
    );
  }

  Widget _prayerCard(Prayer p, bool isNext, ColorScheme scheme) {
    return Card(
      color: isNext ? scheme.primaryContainer : null,
      shape: isNext
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.am,
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(p.en),
                    ],
                  ),
                ),
                if (isNext)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.notifications_active),
                  ),
                TextButton(
                  onPressed: () => _pickTime(p),
                  child: Column(
                    children: [
                      Text(p.clock24, style: const TextStyle(fontSize: 20)),
                      Text('ሰዓት ${p.ethClock}',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<Mode>(
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
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: const Text('ምክንያት እና ጥቅስ'),
              children: [
                Text(p.reason),
                const SizedBox(height: 8),
                Text(p.verse,
                    style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text('ጸሎቶች እና መዝሙራት (${p.texts.length})'),
              children: [
                for (var i = 0; i < p.texts.length; i++)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.texts[i].title.isNotEmpty)
                          Text(p.texts[i].title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                        SelectableText(p.texts[i].body),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _editText(p, index: i),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _deleteText(p, i),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('ጸሎት / መዝሙር ጨምር · Add'),
                    onPressed: () => _editText(p),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final next = findNext();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ሰባቱ ጊዜ ጸሎት · Prayer Notifier')),
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
                'Windows: closing the window keeps the app running in the system tray.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}