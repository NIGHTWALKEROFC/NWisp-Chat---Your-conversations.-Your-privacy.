import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../firebase_options.dart';

const int kCallNotificationId = 9001;
const int kOngoingNotificationId = 9002;
const String kCallChannelId = 'incoming_calls';
const String kOngoingChannelId = 'ongoing_call';

/// Feature: full-screen ringing when NWisp is closed.
///
/// The server sends a DATA-ONLY push for a call (no ready-made notification),
/// so this code runs even with the app closed and builds a call-style
/// notification itself: it rings with the phone's ringtone, lights the screen
/// and pops the ringing screen over the lock screen (a "full-screen intent"),
/// and has Answer / Decline buttons.
///
/// Also owns the small "on a call" foreground service that keeps the
/// microphone alive while NWisp is in the background during a call.
///
/// Note: this file never calls `initialize()` in the main isolate — main.dart
/// already did, and initialising twice would replace its tap handlers.
class IncomingCallNotifier {
  IncomingCallNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static const MethodChannel _window = MethodChannel('com.nightwalker.securechat/call_window');

  /// Set when the person tapped "Answer" on the notification. HomeShell picks
  /// it up as soon as the matching ringing call appears and answers by itself.
  static String? pendingAnswerCallId;
  static String? pendingJoinGroupCallId;

  static Future<void> createChannels(AndroidFlutterLocalNotificationsPlugin? android) async {
    if (android == null) return;
    await android.createNotificationChannel(AndroidNotificationChannel(
      kCallChannelId,
      'Incoming calls',
      description: 'Rings when someone calls you on NWisp',
      importance: Importance.max,
      playSound: true,
      sound: UriAndroidNotificationSound('content://settings/system/ringtone'),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      enableVibration: true,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      kOngoingChannelId,
      'Ongoing call',
      description: 'Shown while you are on a NWisp call',
      importance: Importance.low,
      playSound: false,
    ));
  }

  static AndroidNotificationDetails _ringDetails() => AndroidNotificationDetails(
        kCallChannelId,
        'Incoming calls',
        channelDescription: 'Rings when someone calls you on NWisp',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        timeoutAfter: 45000,
        visibility: NotificationVisibility.public,
        playSound: true,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        // FLAG_INSISTENT (4): keep ringing until answered, declined or timed out.
        additionalFlags: Int32List.fromList(<int>[4]),
        ticker: 'Incoming call',
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction('decline', 'Decline', showsUserInterface: false, cancelNotification: true),
          AndroidNotificationAction('answer', 'Answer', showsUserInterface: true, cancelNotification: true),
        ],
      );

  /// Called from the background push handler, in a fresh isolate.
  static Future<void> showFromBackground(Map<String, dynamic> data) async {
    final type = data['type'];
    final id = (data['callId'] as String?) ?? '';
    if (id.isEmpty) return;
    await _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveBackgroundNotificationResponse: nwispCallActionBackground,
    );
    await createChannels(_plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>());
    final name = (data['callerName'] as String?) ?? 'Someone';
    final isGroup = type == 'incoming_group_call';
    final group = (data['groupName'] as String?) ?? 'a group';
    await _plugin.show(
      kCallNotificationId,
      isGroup ? 'Group voice call' : 'Incoming voice call',
      isGroup ? '$name is calling $group' : '$name is calling you',
      NotificationDetails(android: _ringDetails()),
      payload: '${isGroup ? 'gcall' : 'call'}|$id',
    );
  }

  /// Android 14+ can switch "full-screen notifications" off for an app.
  /// This asks for it (opens the system page if needed). Returns null when
  /// it isn't applicable on this phone.
  static Future<bool?> requestFullScreenPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestFullScreenIntentPermission();
    } catch (_) {
      return null;
    }
  }

  static Future<void> cancelRing() async {
    try {
      await _plugin.cancel(kCallNotificationId);
    } catch (_) {}
  }

  /// A tap / button press on the call notification, main isolate.
  static Future<void> handleResponse(NotificationResponse r) async {
    final payload = r.payload ?? '';
    final parts = payload.split('|');
    if (parts.length < 2 || (parts[0] != 'call' && parts[0] != 'gcall')) return;
    final id = parts[1];
    if (r.actionId == 'answer') {
      if (parts[0] == 'call') {
        pendingAnswerCallId = id;
      } else {
        pendingJoinGroupCallId = id;
      }
    } else if (r.actionId == 'decline' && parts[0] == 'call') {
      try {
        await FirebaseFirestore.instance.collection('calls').doc(id).update({'status': 'declined'});
      } catch (_) {}
    }
  }

  static bool isCallPayload(String? payload) =>
      payload != null && (payload.startsWith('call|') || payload.startsWith('gcall|'));

  // -------------------------------------------------- lock-screen window
  /// Lets the ringing / in-call screen show over the lock screen and light
  /// the display. Turned off again when the call is over.
  static Future<void> showOverLockScreen(bool on) async {
    try {
      await _window.invokeMethod('show', {'on': on});
    } catch (_) {}
  }

  // ------------------------------------------- "on a call" foreground service
  static Future<void> startOngoing(String label) async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.startForegroundService(
        kOngoingNotificationId,
        'NWisp voice call',
        label,
        notificationDetails: const AndroidNotificationDetails(
          kOngoingChannelId,
          'Ongoing call',
          channelDescription: 'Shown while you are on a NWisp call',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          category: AndroidNotificationCategory.call,
          playSound: false,
        ),
        foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeMicrophone},
      );
    } catch (_) {}
  }

  static Future<void> stopOngoing() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.stopForegroundService();
    } catch (_) {}
  }
}

/// Runs in its own isolate when a call push arrives and NWisp is not open.
@pragma('vm:entry-point')
Future<void> nwispFirebaseBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type'];
  if (type != 'incoming_call' && type != 'incoming_group_call') return;
  final sent = message.sentTime;
  // A ring that is already stale is not worth showing.
  if (sent != null && DateTime.now().difference(sent) > const Duration(seconds: 40)) return;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {}
  await IncomingCallNotifier.showFromBackground(message.data);
}

/// "Decline" pressed on the notification while NWisp is closed.
@pragma('vm:entry-point')
Future<void> nwispCallActionBackground(NotificationResponse r) async {
  if (r.actionId != 'decline') return;
  final parts = (r.payload ?? '').split('|');
  if (parts.length < 2 || parts[0] != 'call') return;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {}
  try {
    // The saved login is restored asynchronously in a fresh isolate.
    await FirebaseAuth.instance.authStateChanges().first.timeout(const Duration(seconds: 5));
    await FirebaseFirestore.instance.collection('calls').doc(parts[1]).update({'status': 'declined'});
  } catch (_) {}
}
