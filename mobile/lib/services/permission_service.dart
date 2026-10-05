import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'incoming_call_notifier.dart';

/// One permission group the app can use, in plain words.
class AppPermission {
  final String id;
  final String title;
  final String why;
  final IconData icon;
  final List<Permission> perms;

  /// Location "Always" can only be asked after "While using the app".
  final bool needsLocationFirst;

  /// The full-screen call notification has no readable status on Android.
  final bool special;
  const AppPermission({
    required this.id,
    required this.title,
    required this.why,
    required this.icon,
    this.perms = const [],
    this.needsLocationFirst = false,
    this.special = false,
  });
}

/// Feature: one place for every permission NWisp can use — asked together on
/// first start, and managed in Settings → Permissions.
///
/// Android rule (not something an app can change): an app can ASK for a
/// permission, but only the phone's own Settings page can TAKE IT BACK. So
/// "turn off" opens that page.
class PermissionService {
  PermissionService._();

  static const _kIntroSeen = 'permissions_intro_seen';

  static const all = <AppPermission>[
    AppPermission(
      id: 'notifications',
      title: 'Notifications',
      why: 'New messages and incoming calls.',
      icon: Icons.notifications_active_outlined,
      perms: [Permission.notification],
    ),
    AppPermission(
      id: 'calls',
      title: 'Full-screen calls',
      why: 'Shows an incoming call over the whole screen, even when the phone is locked.',
      icon: Icons.phone_in_talk_outlined,
      special: true,
    ),
    AppPermission(
      id: 'microphone',
      title: 'Microphone',
      why: 'Voice calls and voice messages.',
      icon: Icons.mic_none_rounded,
      perms: [Permission.microphone],
    ),
    AppPermission(
      id: 'camera',
      title: 'Camera',
      why: 'Scanning QR codes, taking photos and videos for chats and stories.',
      icon: Icons.photo_camera_outlined,
      perms: [Permission.camera],
    ),
    AppPermission(
      id: 'location',
      title: 'Location — while using the app',
      why: 'Sharing your location in a chat, and finding people nearby.',
      icon: Icons.location_on_outlined,
      perms: [Permission.locationWhenInUse],
    ),
    AppPermission(
      id: 'location_always',
      title: 'Location — all the time',
      why: 'Only for live location that keeps updating while the app is closed.',
      icon: Icons.my_location_rounded,
      perms: [Permission.locationAlways],
      needsLocationFirst: true,
    ),
    AppPermission(
      id: 'nearby',
      title: 'Nearby devices',
      why: 'Nearby chat over Bluetooth and Wi-Fi, with no internet.',
      icon: Icons.bluetooth_searching_rounded,
      perms: [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.bluetoothAdvertise],
    ),
  ];

  static Future<bool> isGranted(AppPermission p) async {
    if (p.special) return false; // unknown — shown as "Tap to allow"
    if (p.perms.isEmpty) return false;
    for (final perm in p.perms) {
      final s = await perm.status;
      // On phones where a permission doesn't exist (e.g. Bluetooth on very old
      // Android) the plugin reports granted/limited — count both as fine.
      if (!(s.isGranted || s.isLimited)) return false;
    }
    return true;
  }

  static Future<bool> isPermanentlyDenied(AppPermission p) async {
    for (final perm in p.perms) {
      if (await perm.isPermanentlyDenied) return true;
    }
    return false;
  }

  /// Asks for one group. Returns true if it ended up allowed.
  static Future<bool> request(AppPermission p) async {
    if (p.special) {
      await IncomingCallNotifier.requestFullScreenPermission();
      return true;
    }
    if (p.needsLocationFirst && !await Permission.locationWhenInUse.isGranted) {
      await Permission.locationWhenInUse.request();
    }
    await p.perms.request();
    return isGranted(p);
  }

  /// Asks for everything, one after another.
  static Future<void> requestAll() async {
    for (final p in all) {
      try {
        await request(p);
      } catch (_) {}
    }
  }

  static Future<void> openSystemSettings() => openAppSettings();

  static Future<bool> introSeen() async => (await SharedPreferences.getInstance()).getBool(_kIntroSeen) ?? false;

  static Future<void> markIntroSeen() async => (await SharedPreferences.getInstance()).setBool(_kIntroSeen, true);
}
