import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The person's quiet-hours setting, as shown in Settings > Notifications.
class QuietHours {
  final bool enabled;

  /// Minutes after midnight, local time (23:00 = 1380).
  final int startMin;
  final int endMin;
  const QuietHours({required this.enabled, required this.startMin, required this.endMin});

  static const defaults = QuietHours(enabled: false, startMin: 23 * 60, endMin: 7 * 60);
}

/// Feature: Do Not Disturb schedule ("quiet hours").
///
/// While quiet hours are on, the server simply doesn't send message push
/// notifications between the start and end time — nothing buzzes or lights the
/// screen. Messages are not lost: they're waiting in the chat when the app is
/// opened. Account security alerts (NWisp Chat Notifications) and incoming
/// calls are NOT paused — those are the things you'd want to be woken for.
///
/// The check has to happen on the server (the push is sent from there, see
/// supabase/functions/send-push), so the settings are copied to this account's
/// private profile document, together with this phone's current time-zone
/// offset so "11 PM" means 11 PM where the person actually is. The offset is
/// refreshed every time the app starts (main.dart), which also covers daylight
/// saving changes.
///
/// The settings are saved per account on this phone (SharedPreferences) — not
/// sensitive, and keyed by uid so a different account signing in on the same
/// phone doesn't inherit them.
class QuietHoursService {
  QuietHoursService._();
  static final instance = QuietHoursService._();

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String _key(String name) => 'quiet_hours_${_uid ?? 'none'}_$name';

  Future<QuietHours> load() async {
    final prefs = await SharedPreferences.getInstance();
    return QuietHours(
      enabled: prefs.getBool(_key('enabled')) ?? QuietHours.defaults.enabled,
      startMin: prefs.getInt(_key('start')) ?? QuietHours.defaults.startMin,
      endMin: prefs.getInt(_key('end')) ?? QuietHours.defaults.endMin,
    );
  }

  Future<void> save(QuietHours value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('enabled'), value.enabled);
    await prefs.setInt(_key('start'), value.startMin);
    await prefs.setInt(_key('end'), value.endMin);
    await syncToProfile();
  }

  /// Copies the current setting (and this phone's UTC offset) to the
  /// account's private profile, where the push function reads it. Safe to
  /// call any time; does nothing when signed out. Failures are ignored —
  /// worst case the server keeps using the last values it was given.
  Future<void> syncToProfile() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final value = await load();
      await FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('profile').set(
        {
          'quietHours': {
            'enabled': value.enabled,
            'startMin': value.startMin,
            'endMin': value.endMin,
            'utcOffsetMin': DateTime.now().timeZoneOffset.inMinutes,
          },
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('QuietHoursService.syncToProfile failed: $e');
    }
  }
}
