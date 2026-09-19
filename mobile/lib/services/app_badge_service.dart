import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'settings_service.dart';

/// Feature: unread-count badge on the app icon.
///
/// ChatListScreen works out the number (it's the one place that knows which
/// chats are hidden, muted, archived or paused — see its _updateBadge) and
/// hands it to [update]. This class only owns talking to the launcher:
/// skipping redundant calls, honouring the on/off switch in
/// Settings > Notifications, and never letting a launcher that doesn't
/// support badges throw into the rest of the app.
///
/// Honest limits (Android has no official badge API):
///  * Samsung, Oppo, Vivo, Huawei, Xiaomi and similar launchers show a real
///    number. Stock Android / Pixel launchers only ever show a plain "dot"
///    driven by active notifications, whatever number is set here.
///  * On Android 13+ the badge also needs the notification permission the
///    app already asks for at startup.
class AppBadgeService {
  AppBadgeService._();
  static final instance = AppBadgeService._();

  int _lastRequested = 0;
  int? _lastApplied;

  /// Sets the badge to [count] (0 clears it). No-ops if nothing changed.
  Future<void> update(int count) async {
    _lastRequested = count < 0 ? 0 : count;
    final enabled = await SettingsService.getAppBadgeEnabled();
    final capped = _lastRequested > 9999 ? 9999 : _lastRequested;
    final effective = enabled ? capped : 0;
    if (_lastApplied == effective) return;
    _lastApplied = effective;
    try {
      await AppBadgePlus.updateBadge(effective);
    } catch (e) {
      debugPrint('AppBadgeService: could not update badge: $e');
    }
  }

  /// Re-applies the last known count — used right after the person flips the
  /// badge switch in Settings, so the change shows up immediately.
  Future<void> refresh() async {
    _lastApplied = null;
    await update(_lastRequested);
  }

  /// Clears the badge outright — called on sign-out so one account's unread
  /// count never lingers on the icon after that account is gone.
  Future<void> clear() async {
    _lastRequested = 0;
    _lastApplied = 0;
    try {
      await AppBadgePlus.updateBadge(0);
    } catch (e) {
      debugPrint('AppBadgeService: could not clear badge: $e');
    }
  }
}
