import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_badge_service.dart';
import 'app_lock_service.dart';
import 'auth_service.dart';
import 'device_session_service.dart';
import 'moderation_service.dart';
import 'private_keyboard_service.dart';
import 'screenshot_guard_service.dart';
import 'settings_service.dart';

/// The four pages of the guided checkup.
enum PrivacyStep { lock, visibility, notifications, device }

extension PrivacyStepInfo on PrivacyStep {
  String get title {
    switch (this) {
      case PrivacyStep.lock:
        return 'Lock your app';
      case PrivacyStep.visibility:
        return 'Control what others see';
      case PrivacyStep.notifications:
        return 'Keep notifications quiet';
      case PrivacyStep.device:
        return 'Protect this phone and your account';
    }
  }

  String get intro {
    switch (this) {
      case PrivacyStep.lock:
        return 'Stops anyone who picks up your phone from reading your chats.';
      case PrivacyStep.visibility:
        return 'Decide what people you chat with can find out about you.';
      case PrivacyStep.notifications:
        return 'What a locked screen or a glance at your phone can reveal.';
      case PrivacyStep.device:
        return 'Extra protection for the phone itself and for signing in.';
    }
  }
}

/// One privacy / security setting the checkup looks at. "On" always means
/// the PRIVATE choice (e.g. "Hide last seen" is on when last seen is hidden).
class PrivacyItem {
  final String id;
  final PrivacyStep step;
  final IconData icon;
  final String title;
  final String description;

  /// Only makes sense while the app lock is on.
  final bool needsAppLock;

  /// False when the checkup cannot switch it on by itself (it needs a PIN to
  /// be chosen by the person).
  final bool autoEnable;

  const PrivacyItem(this.id, this.step, this.icon, this.title, this.description, {this.needsAppLock = false, this.autoEnable = true});
}

/// The 12 checks. Order = order shown.
const List<PrivacyItem> kPrivacyItems = [
  PrivacyItem('app_lock', PrivacyStep.lock, Icons.pin_outlined, 'App lock (PIN)',
      'Ask for a PIN every time the app is opened. You choose the PIN yourself, so this one is set up by you.',
      autoEnable: false),
  PrivacyItem('lock_immediately', PrivacyStep.lock, Icons.lock_clock_outlined, 'Lock as soon as you leave',
      'Asks for the PIN the moment you switch to another app.',
      needsAppLock: true),
  PrivacyItem('idle_lock', PrivacyStep.lock, Icons.timer_outlined, 'Auto-lock after 5 minutes idle',
      'Locks itself if you stop touching the screen for 5 minutes, even if the app stays open.',
      needsAppLock: true),
  PrivacyItem('shake_lock', PrivacyStep.lock, Icons.vibration, 'Shake to lock',
      'Shake the phone firmly to lock the app instantly from anywhere in it.',
      needsAppLock: true),
  PrivacyItem('hide_read_receipts', PrivacyStep.visibility, Icons.done_all, 'Hide read receipts',
      'People no longer see when you have read their messages (and you no longer see theirs).'),
  PrivacyItem('hide_last_seen', PrivacyStep.visibility, Icons.visibility_off_outlined, 'Hide last seen and online',
      'Nobody can see when you were last online.'),
  PrivacyItem('hide_notif_names', PrivacyStep.notifications, Icons.person_off_outlined, 'Hide sender names in notifications',
      'A notification says "New message" instead of who sent it.'),
  PrivacyItem('hide_notif_content', PrivacyStep.notifications, Icons.notifications_off_outlined, 'Hide message previews in notifications',
      'Notifications show nothing about what the message contains.'),
  PrivacyItem('hide_badge', PrivacyStep.notifications, Icons.circle_notifications_outlined, 'Hide unread count on the app icon',
      'The app icon stops showing a number, so nobody can tell if you have new messages.'),
  PrivacyItem('hide_recents', PrivacyStep.device, Icons.web_asset_off_outlined, 'Hide app in the recent-apps screen',
      'The app switcher shows a blank card instead of your chats.'),
  PrivacyItem('private_keyboard', PrivacyStep.device, Icons.keyboard_alt_outlined, 'Private keyboard',
      'Asks your keyboard not to learn from or suggest what you type here.'),
  PrivacyItem('login_approval', PrivacyStep.device, Icons.verified_user_outlined, 'Approve new logins',
      'A new login must be accepted from this phone before it can sign in to your account.'),
];

/// Everything the checkup can do: read the settings, flip one, or flip all
/// of them for the "100% private" preset — with a one-tap undo.
///
/// NOT part of the preset, on purpose: settings that DELETE things
/// (auto-delete messages, auto-wipe inactive chats). Those destroy data, so
/// they stay a deliberate choice in Settings.
class PrivacyCheckupService {
  PrivacyCheckupService._();

  static const _undoKey = 'privacy_checkup_undo';

  // ---- reading -----------------------------------------------------------

  /// The raw current value of every setting the checkup touches.
  static Future<Map<String, dynamic>> readRaw() async {
    final raw = <String, dynamic>{
      'appLock': await AppLockService.isEnabled(),
      'grace': await AppLockService.getBackgroundGraceMinutes(),
      'idle': await AppLockService.getIdleTimeoutMinutes(),
      'shake': await AppLockService.getShakeToLockEnabled(),
      'recents': await SettingsService.getHideRecentsPreview(),
      'keyboard': await SettingsService.getPrivateKeyboardEnabled(),
      'badge': await SettingsService.getAppBadgeEnabled(),
      'receipts': true,
      'lastSeen': true,
      'notifNames': false,
      'notifContent': false,
      'loginApproval': false,
    };
    try {
      final data = (await AuthService().currentUserPrivateProfile()).data() ?? {};
      raw['receipts'] = (data['readReceiptsEnabled'] as bool?) ?? true;
      raw['lastSeen'] = (data['lastSeenVisible'] as bool?) ?? true;
      raw['notifNames'] = (data['notificationPrivacyGlobal'] as bool?) ?? false;
      raw['notifContent'] = (data['notificationPrivacyHideContentGlobal'] as bool?) ?? false;
    } catch (_) {}
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) raw['loginApproval'] = await DeviceSessionService.instance.isLoginApprovalRequired(uid);
    } catch (_) {}
    return raw;
  }

  /// Is this check currently ON (= the private choice)?
  static bool isOn(String id, Map<String, dynamic> raw) {
    final lock = raw['appLock'] == true;
    final idle = raw['idle'] as int?;
    switch (id) {
      case 'app_lock':
        return lock;
      case 'lock_immediately':
        return lock && raw['grace'] == 0;
      case 'idle_lock':
        return lock && idle != null && idle > 0 && idle <= 5;
      case 'shake_lock':
        return lock && raw['shake'] == true;
      case 'hide_read_receipts':
        return raw['receipts'] == false;
      case 'hide_last_seen':
        return raw['lastSeen'] == false;
      case 'hide_notif_names':
        return raw['notifNames'] == true;
      case 'hide_notif_content':
        return raw['notifContent'] == true;
      case 'hide_badge':
        return raw['badge'] == false;
      case 'hide_recents':
        return raw['recents'] == true;
      case 'private_keyboard':
        return raw['keyboard'] == true;
      case 'login_approval':
        return raw['loginApproval'] == true;
    }
    return false;
  }

  static int score(Map<String, dynamic> raw) => kPrivacyItems.where((i) => isOn(i.id, raw)).length;

  // ---- writing one setting -------------------------------------------------

  /// Turns one check on (private) or off. `app_lock` is not handled here —
  /// it needs a PIN screen.
  static Future<void> setItem(String id, bool on) async {
    switch (id) {
      case 'lock_immediately':
        // "Off" = allow 5 minutes away before asking for the PIN again.
        await AppLockService.setBackgroundGraceMinutes(on ? 0 : 5);
        break;
      case 'idle_lock':
        await AppLockService.setIdleTimeoutMinutes(on ? 5 : null);
        break;
      case 'shake_lock':
        await AppLockService.setShakeToLockEnabled(on);
        break;
      case 'hide_read_receipts':
        await AuthService().updatePrivacySetting('readReceiptsEnabled', !on);
        break;
      case 'hide_last_seen':
        await AuthService().updatePrivacySetting('lastSeenVisible', !on);
        break;
      case 'hide_notif_names':
        await ModerationService().setNotificationPrivacyGlobal(on);
        break;
      case 'hide_notif_content':
        await ModerationService().setNotificationContentPrivacyGlobal(on);
        break;
      case 'hide_badge':
        await SettingsService.setAppBadgeEnabled(!on);
        await AppBadgeService.instance.refresh();
        break;
      case 'hide_recents':
        await SettingsService.setHideRecentsPreview(on);
        await ScreenshotGuardService.setRecentsPreviewHidden(on);
        break;
      case 'private_keyboard':
        await PrivateKeyboardService.setEnabled(on);
        break;
      case 'login_approval':
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) await DeviceSessionService.instance.setRequireLoginApproval(uid, on);
        break;
    }
  }

  // ---- the "100% private" preset --------------------------------------------

  /// The checks the preset WOULD switch on right now: everything that is off
  /// and can be switched on automatically. Checks that depend on the app
  /// lock are left out while the lock itself is off.
  static List<PrivacyItem> plan(Map<String, dynamic> raw) {
    final lock = raw['appLock'] == true;
    return kPrivacyItems.where((i) {
      if (!i.autoEnable) return false;
      if (i.needsAppLock && !lock) return false;
      return !isOn(i.id, raw);
    }).toList();
  }

  static const Map<String, String> _rawKeyFor = {
    'lock_immediately': 'grace',
    'idle_lock': 'idle',
    'shake_lock': 'shake',
    'hide_read_receipts': 'receipts',
    'hide_last_seen': 'lastSeen',
    'hide_notif_names': 'notifNames',
    'hide_notif_content': 'notifContent',
    'hide_badge': 'badge',
    'hide_recents': 'recents',
    'private_keyboard': 'keyboard',
    'login_approval': 'loginApproval',
  };

  /// Switches on everything in [plan], remembering the old values of exactly
  /// those settings so [undoLastLockdown] can put them back.
  static Future<int> applyLockdown(Map<String, dynamic> raw) async {
    final items = plan(raw);
    final undo = <String, dynamic>{};
    for (final item in items) {
      final key = _rawKeyFor[item.id];
      if (key != null) undo[key] = raw[key];
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_undoKey, jsonEncode(undo));
    var changed = 0;
    for (final item in items) {
      try {
        await setItem(item.id, true);
        changed++;
      } catch (_) {}
    }
    return changed;
  }

  static Future<bool> hasUndo() async {
    final s = (await SharedPreferences.getInstance()).getString(_undoKey);
    return s != null && s != '{}';
  }

  /// Puts back the values the last preset changed.
  static Future<void> undoLastLockdown() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_undoKey);
    if (s == null) return;
    final undo = Map<String, dynamic>.from(jsonDecode(s) as Map);
    for (final entry in undo.entries) {
      final v = entry.value;
      try {
        switch (entry.key) {
          case 'grace':
            await AppLockService.setBackgroundGraceMinutes((v as num?)?.toInt() ?? 0);
            break;
          case 'idle':
            await AppLockService.setIdleTimeoutMinutes((v as num?)?.toInt());
            break;
          case 'shake':
            await AppLockService.setShakeToLockEnabled(v == true);
            break;
          case 'receipts':
            await AuthService().updatePrivacySetting('readReceiptsEnabled', v != false);
            break;
          case 'lastSeen':
            await AuthService().updatePrivacySetting('lastSeenVisible', v != false);
            break;
          case 'notifNames':
            await ModerationService().setNotificationPrivacyGlobal(v == true);
            break;
          case 'notifContent':
            await ModerationService().setNotificationContentPrivacyGlobal(v == true);
            break;
          case 'badge':
            await SettingsService.setAppBadgeEnabled(v != false);
            await AppBadgeService.instance.refresh();
            break;
          case 'recents':
            await SettingsService.setHideRecentsPreview(v == true);
            await ScreenshotGuardService.setRecentsPreviewHidden(v == true);
            break;
          case 'keyboard':
            await PrivateKeyboardService.setEnabled(v == true);
            break;
          case 'loginApproval':
            final uid = FirebaseAuth.instance.currentUser?.uid;
            if (uid != null) await DeviceSessionService.instance.setRequireLoginApproval(uid, v == true);
            break;
        }
      } catch (_) {}
    }
    await prefs.remove(_undoKey);
  }
}
