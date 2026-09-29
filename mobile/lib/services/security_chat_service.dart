import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_session_service.dart';

/// One message in the official "NWisp Chat" conversation.
class SecurityNotice {
  final String id;
  final String event;
  final String title;
  final String body;
  final IconData icon;

  /// True for things that should make someone stop and check (a password
  /// change, 2FA switched off, a new sign-in) — drawn with the warning tint.
  final bool needsAttention;
  final DateTime? time;

  const SecurityNotice({
    required this.id,
    required this.event,
    required this.title,
    required this.body,
    required this.icon,
    required this.needsAttention,
    required this.time,
  });
}

/// What the chat list needs to draw the pinned "NWisp Chat" row.
class SecurityChatSummary {
  final SecurityNotice? latest;
  final int unread;
  const SecurityChatSummary({required this.latest, required this.unread});
}

/// Feature: the official "NWisp Chat" conversation (like Telegram's
/// service-notification chat).
///
/// It is NOT a real chat and there's no server-side "NWisp account": the
/// messages are just the account's own security history
/// (users/{uid}/private/session/history — the append-only log
/// DeviceSessionService already writes on every login and password change,
/// plus the 2FA events added with this feature) drawn as chat bubbles.
/// Nothing new is stored anywhere, nothing passes through the encrypted
/// message relay, and there's nobody to reply to.
///
/// "Clear activity" on the Account Security screen hides the same entries
/// here, since it's the same list.
///
/// Which notices you've already seen is remembered on this phone only.
class SecurityChatService {
  SecurityChatService._();
  static final instance = SecurityChatService._();

  static const _kLastRead = 'security_chat_last_read_ms';

  /// Bumped by [markRead] so the chat-list row redraws without waiting for
  /// Firestore to send something new.
  final ValueNotifier<int> readTick = ValueNotifier(0);

  Future<int> _lastReadMs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLastRead) ?? 0;
  }

  /// Marks everything up to now as seen (called while the chat is open).
  Future<void> markRead() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastRead, DateTime.now().millisecondsSinceEpoch);
    readTick.value++;
  }

  /// The cut-off set by "Clear activity" (null = never cleared).
  Stream<DateTime?> _clearedAt(String uid) => DeviceSessionService.instance
      .sessionStream(uid)
      .map((s) => (s.data()?['historyClearedAt'] as Timestamp?)?.toDate());

  /// The full list of notices, newest first.
  Stream<List<SecurityNotice>> notices(String uid) {
    return _clearedAt(uid).asyncExpand((cleared) {
      return DeviceSessionService.instance.historyStream(uid, after: cleared).map(
            (snap) => snap.docs.map((d) => fromHistory(d.id, d.data())).toList(),
          );
    });
  }

  /// Latest notice + unread count, for the chat list row.
  Stream<SecurityChatSummary> summary(String uid) {
    return notices(uid).asyncMap((list) async {
      final lastRead = await _lastReadMs();
      final unread = list.where((n) => n.time != null && n.time!.millisecondsSinceEpoch > lastRead).length;
      return SecurityChatSummary(latest: list.isEmpty ? null : list.first, unread: unread);
    });
  }

  /// Turns one history entry into the message the official account "sends".
  static SecurityNotice fromHistory(String id, Map<String, dynamic> data) {
    final event = (data['event'] as String?) ?? '';
    final device = (data['deviceLabel'] as String?) ?? 'a device';
    final location = data['location'] as String?;
    final where = (location != null && location.isNotEmpty) ? '$device · $location' : device;
    final time = (data['timestamp'] as Timestamp?)?.toDate();

    switch (event) {
      case 'login':
        return SecurityNotice(
          id: id,
          event: event,
          title: 'New sign-in',
          body: 'Your account was signed in on $where.\n\nIf this was you, you can ignore this message. '
              "If not, change your password right away.",
          icon: Icons.login_rounded,
          needsAttention: true,
          time: time,
        );
      case 'password_changed':
        return SecurityNotice(
          id: id,
          event: event,
          title: 'Password changed',
          body: 'Your password was changed from $where.\n\nIf you didn\'t do this, reset your password now and '
              'turn on two-step verification.',
          icon: Icons.password_rounded,
          needsAttention: true,
          time: time,
        );
      case 'totp_enabled':
        return SecurityNotice(
          id: id,
          event: event,
          title: 'Two-step verification is on',
          body: 'Two-step verification was turned on from $where. '
              'Signing in now needs a code from your authenticator app.',
          icon: Icons.verified_user_rounded,
          needsAttention: false,
          time: time,
        );
      case 'totp_disabled':
        return SecurityNotice(
          id: id,
          event: event,
          title: 'Two-step verification was turned off',
          body: 'Two-step verification was turned OFF from $where.\n\nIf this wasn\'t you, someone may have '
              'access to your account — change your password now.',
          icon: Icons.gpp_maybe_rounded,
          needsAttention: true,
          time: time,
        );
      default:
        return SecurityNotice(
          id: id,
          event: event,
          title: 'Security event',
          body: 'Something changed on your account from $where.',
          icon: Icons.security_rounded,
          needsAttention: false,
          time: time,
        );
    }
  }
}
