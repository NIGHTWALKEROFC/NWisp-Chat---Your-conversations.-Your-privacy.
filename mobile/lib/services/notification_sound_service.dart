import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: custom notification sound.
///
/// On Android 8+ a notification's sound belongs to its *notification
/// channel* and can't be changed once that channel exists. So picking a new
/// sound means creating a NEW channel (named after the sound) and using that
/// one from then on — the old custom channel is deleted so the phone's own
/// notification settings stay tidy.
///
/// Two places need to know which channel to use:
///  * the app itself, when it shows a notification while it's open (main.dart
///    asks [currentChannelId]);
///  * the server's push function, for notifications that arrive while the app
///    is closed. It reads `notificationChannelId` from this account's private
///    profile document, which [syncToProfile] keeps up to date.
///
/// The choice is saved on this device only (SharedPreferences) — it's a
/// personal preference, not something other people can see.
class NotificationSoundService {
  NotificationSoundService._();
  static final instance = NotificationSoundService._();

  static const defaultChannelId = 'messages';
  static const _channel = MethodChannel('com.nightwalker.securechat/notification_sound');

  static const _kUri = 'notif_sound_uri'; // '' = silent, null/absent = phone default
  static const _kTitle = 'notif_sound_title';
  static const _kChannelId = 'notif_sound_channel_id';

  final _plugin = FlutterLocalNotificationsPlugin();

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The channel notifications should be posted to right now.
  Future<String> currentChannelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kChannelId) ?? defaultChannelId;
  }

  /// Name shown in Settings > Notifications > Sounds.
  Future<String> currentSoundLabel() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kChannelId) == null) return 'Default';
    return prefs.getString(_kTitle) ?? 'Custom sound';
  }

  Future<bool> hasCustomSound() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kChannelId) != null;
  }

  /// Call once at startup, after flutter_local_notifications is initialised:
  /// makes sure the chosen channel exists (a no-op if it already does — this
  /// matters after an app update or a "clear data").
  Future<void> ensureChannel() async {
    if (!_supported) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kChannelId);
    if (id == null) return; // default 'messages' channel is created by main.dart
    await _createChannel(id, prefs.getString(_kUri) ?? '', prefs.getString(_kTitle) ?? 'Custom sound');
  }

  /// Opens Android's own sound picker. Returns the chosen sound's name, or
  /// null if the person backed out (nothing changes in that case).
  Future<String?> pickSound() async {
    if (!_supported) return null;
    final prefs = await SharedPreferences.getInstance();
    Map<dynamic, dynamic>? picked;
    try {
      picked = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickSound', {
        'current': prefs.getString(_kUri),
      });
    } on PlatformException {
      rethrow;
    }
    if (picked == null) return null;

    final uri = (picked['uri'] as String?) ?? '';
    final title = (picked['title'] as String?) ?? 'Custom sound';
    final newId = 'messages_${_fnv(uri.isEmpty ? 'silent' : uri)}';
    final oldId = prefs.getString(_kChannelId);

    await _createChannel(newId, uri, title);
    await prefs.setString(_kUri, uri);
    await prefs.setString(_kTitle, title);
    await prefs.setString(_kChannelId, newId);
    if (oldId != null && oldId != newId) await _deleteChannel(oldId);
    await syncToProfile();
    return title;
  }

  /// Goes back to the phone's normal notification sound.
  Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    final oldId = prefs.getString(_kChannelId);
    await prefs.remove(_kUri);
    await prefs.remove(_kTitle);
    await prefs.remove(_kChannelId);
    if (oldId != null) await _deleteChannel(oldId);
    await syncToProfile();
  }

  /// Tells the server which channel this account's notifications should use
  /// (see supabase/functions/send-push). Safe to call any time; does nothing
  /// when signed out. Failures are ignored — worst case, pushes that arrive
  /// while the app is closed use the default sound until the next sync.
  Future<void> syncToProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final id = await currentChannelId();
      await FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('profile').set(
        {'notificationChannelId': id},
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('NotificationSoundService.syncToProfile failed: $e');
    }
  }

  Future<void> _createChannel(String id, String uri, String title) async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        id,
        'Messages ($title)',
        description: 'New message notifications',
        importance: Importance.high,
        playSound: uri.isNotEmpty,
        sound: uri.isEmpty ? null : UriAndroidNotificationSound(uri),
      ),
    );
  }

  Future<void> _deleteChannel(String id) async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.deleteNotificationChannel(id);
  }

  /// Small stable hash (Dart's String.hashCode isn't guaranteed to be the
  /// same between runs, and the channel name has to be).
  static String _fnv(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }
}
