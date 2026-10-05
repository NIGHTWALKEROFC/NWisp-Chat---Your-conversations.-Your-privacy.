import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// One message the person asked to be reminded about.
class Reminder {
  final int id; // also the notification id
  final String messageId;
  final String conversationId;
  final String peerUid;
  final String peerName;
  final String preview;
  final DateTime at;

  const Reminder({
    required this.id,
    required this.messageId,
    required this.conversationId,
    required this.peerUid,
    required this.peerName,
    required this.preview,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'm': messageId,
        'c': conversationId,
        'u': peerUid,
        'n': peerName,
        'p': preview,
        't': at.millisecondsSinceEpoch,
      };

  static Reminder fromJson(Map<String, dynamic> j) => Reminder(
        id: (j['id'] as num).toInt(),
        messageId: j['m'] as String,
        conversationId: j['c'] as String,
        peerUid: (j['u'] as String?) ?? '',
        peerName: (j['n'] as String?) ?? '',
        preview: (j['p'] as String?) ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
      );
}

/// Feature: message reminders ("Remind me later").
///
/// The reminder is a notification scheduled in Android itself, so it appears
/// at the chosen time even if NWisp is closed. It is private to this phone:
/// nobody is told. The notification shows only the sender's name and the
/// first words of the message you picked; tapping it opens that chat.
///
/// Android 12+ may delay a reminder by a few minutes unless the app is
/// allowed to set exact alarms — the app asks for that the first time.
class ReminderService {
  ReminderService._();
  static final instance = ReminderService._();

  static const channelId = 'nwisp_reminders';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<List<Reminder>> items = ValueNotifier(const []);

  bool _tzReady = false;
  String? _loadedFor;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  void _initTz() {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    _tzReady = true;
  }

  Future<void> load() async {
    final uid = _uid;
    if (uid == null || _loadedFor == uid) return;
    _loadedFor = uid;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('reminders_v1_$uid');
      final list = raw == null ? <Reminder>[] : (jsonDecode(raw) as List).map((e) => Reminder.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      // A reminder whose time already passed was shown by Android — drop it.
      final now = DateTime.now();
      items.value = list.where((r) => r.at.isAfter(now)).toList()..sort((a, b) => a.at.compareTo(b.at));
    } catch (e) {
      debugPrint('ReminderService.load: $e');
    }
  }

  Future<void> _save() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reminders_v1_$uid', jsonEncode(items.value.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  /// Schedules a reminder. Returns false if notifications are not allowed.
  Future<bool> add({
    required String messageId,
    required String conversationId,
    required String peerUid,
    required String peerName,
    required String preview,
    required DateTime at,
  }) async {
    await load();
    _initTz();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final allowed = await android?.requestNotificationsPermission();
    if (allowed == false) return false;

    var exact = false;
    try {
      exact = (await android?.canScheduleExactNotifications()) ?? false;
      if (!exact) exact = (await android?.requestExactAlarmsPermission()) ?? false;
    } catch (_) {}

    await android?.createNotificationChannel(const AndroidNotificationChannel(
      channelId,
      'Reminders',
      description: 'Messages you asked to be reminded about',
      importance: Importance.high,
    ));

    final id = (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 2000000000;
    final cleaned = preview.trim().replaceAll('\n', ' ');
    final shortPreview = cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned;
    await _plugin.zonedSchedule(
      id,
      'Reminder · $peerName',
      shortPreview.isEmpty ? 'A message you wanted to come back to' : shortPreview,
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Reminders',
          channelDescription: 'Messages you asked to be reminded about',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      // Same shape main.dart uses to open a chat from a notification tap.
      payload: '$conversationId|$peerUid|$peerName',
    );
    items.value = [
      ...items.value,
      Reminder(id: id, messageId: messageId, conversationId: conversationId, peerUid: peerUid, peerName: peerName, preview: shortPreview, at: at),
    ]..sort((a, b) => a.at.compareTo(b.at));
    await _save();
    return true;
  }

  Future<void> cancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {}
    items.value = items.value.where((r) => r.id != id).toList();
    await _save();
  }

  void resetMemory() {
    _loadedFor = null;
    items.value = const [];
  }
}
