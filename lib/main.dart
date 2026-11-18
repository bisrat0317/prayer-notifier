import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

enum Mode { sound, silent, off }

class Prayer {
  final int id;
  final String am;
  final String en;
  int minutes; // minutes since midnight
  Mode mode;

  Prayer(this.id, this.am, this.en, this.minutes, {this.mode = Mode.sound});

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

final plugin = FlutterLocalNotificationsPlugin();

List<Prayer> defaultPrayers() => [
      Prayer(1, 'ነግህ', 'Neguh (Dawn)', 6 * 60),
      Prayer(2, 'ሠለስት', 'Third hour', 9 * 60),
      Prayer(3, 'ስድስት', 'Sixth hour', 12 * 60),
      Prayer(4, 'ተስዓት', 'Ninth hour', 15 * 60),
      Prayer(5, 'ዐሥራ አንድ', 'Eleventh hour (Evening)', 17 * 60),
      Prayer(6, 'ንዋም', 'Niwam (Sleep)', 21 * 60),
      Prayer(7, 'መንፈቀ ሌሊት', 'Midnight', 0),
    ];

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
  );

  if (Platform.isAndroid) {
    final a = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await a?.requestNotificationsPermission();
    await a?.requestExactAlarmsPermission();
  }
}

String bodyFor(Prayer p) => 'የጸሎት ጊዜ ደርሷል · ${p.en}';

// ---------- Android: OS-level daily scheduled notification ----------
Future<void> scheduleAndroid(Prayer p) async {
  await plugin.cancel(id: p.id);
  if (p.mode == Mode.off) return;
  final sound = p.mode == Mode.sound;

  final now = tz.TZDateTime.now(tz.local);
  var when = tz.TZDateTime(
      tz.local, now.year, now.month, now.day, p.hour, p.minute);
  if (when.isBefore(now)) when = when.add(const Duration(days: 1));

  await plugin.zonedSchedule(
    id: p.id,
    title: p.am,
    body: bodyFor(p),
    scheduledDate: when,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        sound ? 'prayer_sound' : 'prayer_silent',
        sound ? 'Prayer times (sound)' : 'Prayer times (silent)',
        importance: sound ? Importance.high : Importance.low,
        priority: sound ? Priority.high : Priority.low,
        playSound: sound,
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time, // repeat daily
  );
}

// ---------- Windows: in-app timer (app must be running) ----------
Future<void> showNow(Prayer p) async {
  final sound = p.mode == Mode.sound;
  await plugin.show(
    id: p.id,
    title: p.am,
    body: bodyFor(p),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        sound ? 'prayer_sound' : 'prayer_silent',
        sound ? 'Prayer times (sound)' : 'Prayer times (silent)',
        importance: sound ? Importance.high : Importance.low,
        priority: sound ? Priority.high : Priority.low,
        playSound: sound,
      ),
      windows: WindowsNotificationDetails(
        audio: sound
            ? WindowsNotificationAudio.preset(
                sound: WindowsNotificationSound.alarm1)
            : WindowsNotificationAudio.silent(),
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Prayer Notifier',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF7B3F00),
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final prayers = defaultPrayers();
  Timer? _timer;
  final _firedToday = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    for (final p in prayers) {
      p.minutes = sp.getInt('t${p.id}') ?? p.minutes;
      p.mode = Mode.values[sp.getInt('m${p.id}') ?? Mode.sound.index];
    }
    setState(() {});
    await _apply();

    if (Platform.isWindows) {
      _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    }
  }

  Future<void> _save(Prayer p) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('t${p.id}', p.minutes);
    await sp.setInt('m${p.id}', p.mode.index);
    if (Platform.isAndroid) await scheduleAndroid(p);
  }

  Future<void> _apply() async {
    if (Platform.isAndroid) {
      for (final p in prayers) {
        await scheduleAndroid(p);
      }
    }
  }

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

  Future<void> _pickTime(Prayer p) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: p.hour, minute: p.minute),
    );
    if (t == null) return;
    setState(() => p.minutes = t.hour * 60 + t.minute);
    _save(p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ሰባቱ ጊዜ ጸሎት · Prayer Notifier')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final p in prayers)
            Card(
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
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              Text(p.en),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => _pickTime(p),
                          child: Column(
                            children: [
                              Text(p.clock24,
                                  style: const TextStyle(fontSize: 20)),
                              Text('ሰዓት ${p.ethClock}',
                                  style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<Mode>(
                      segments: const [
                        ButtonSegment(
                            value: Mode.sound,
                            icon: Icon(Icons.volume_up),
                            label: Text('Sound')),
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
                        _save(p);
                      },
                    ),
                  ],
                ),
              ),
            ),
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
                'Windows: keep the app running (minimized) so it can notify you.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
