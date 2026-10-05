import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive app preferences that aren't tied to a specific screen.
/// The "stay signed in" flag is checked by AuthGate at app launch:
/// - true (default)  -> if Firebase already has a session, go straight to chats
/// - false            -> sign the user out on every app launch, always show Login
class SettingsService {
  static const _stayLoggedInKey = 'stay_signed_in';
  static const _hasSeenOnboardingKey = 'has_seen_onboarding';

  static Future<bool> getStayLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_stayLoggedInKey) ?? true;
  }

  static Future<void> setStayLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stayLoggedInKey, value);
  }

  /// Feature: first-run onboarding walkthrough (see OnboardingScreen).
  /// Shown once, ever, per install — set true the moment the person
  /// either finishes it or taps Skip, never reset automatically. This is
  /// a device-local preference (not tied to the account), matching how
  /// "stay signed in" above already works: a fresh install always shows
  /// it once, regardless of which account then signs in.
  static Future<bool> getHasSeenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasSeenOnboardingKey) ?? false;
  }

  static Future<void> setHasSeenOnboarding(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasSeenOnboardingKey, value);
  }

  /// Feature: separate groups and chats on the home screen. Off by
  /// default — the chat list stays merged (chats and groups mixed
  /// together by recency, the way it's always worked) unless someone
  /// deliberately turns this on in Settings.
  static const _separateGroupsAndChatsKey = 'separate_groups_and_chats';

  static Future<bool> getSeparateGroupsAndChats() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_separateGroupsAndChatsKey) ?? false;
  }

  static Future<void> setSeparateGroupsAndChats(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_separateGroupsAndChatsKey, value);
  }

  /// Feature: inactivity auto-wipe. Off by default — see
  /// InactivityWipeService's own doc comment for the full global+per-chat
  /// override design. This is just the GLOBAL default half of it.
  static const _inactivityWipeEnabledKey = 'inactivity_wipe_global_enabled';
  static const _inactivityWipeMonthsKey = 'inactivity_wipe_global_months';

  static Future<bool> getInactivityWipeGlobalEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_inactivityWipeEnabledKey) ?? false;
  }

  static Future<void> setInactivityWipeGlobalEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_inactivityWipeEnabledKey, value);
  }

  static Future<int> getInactivityWipeGlobalMonths() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_inactivityWipeMonthsKey) ?? 3;
  }

  static Future<void> setInactivityWipeGlobalMonths(int months) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_inactivityWipeMonthsKey, months);
  }

  /// Feature: unread-count badge on the app icon (see AppBadgeService). On
  /// by default — it's the normal, expected behaviour — but it can be turned
  /// off in Settings > Notifications for anyone who doesn't want a number
  /// visible on their home screen.
  static const _appBadgeEnabledKey = 'app_icon_badge_enabled';

  static Future<bool> getAppBadgeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appBadgeEnabledKey) ?? true;
  }

  static Future<void> setAppBadgeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appBadgeEnabledKey, value);
  }

  /// Feature: private keyboard mode (see PrivateKeyboardService). OFF by
  /// default — the normal keyboard behaviour (suggestions, autocorrect,
  /// learning from what you type) is what everyone gets until they choose
  /// otherwise in Settings > Privacy.
  static const _privateKeyboardKey = 'private_keyboard_enabled';

  static Future<bool> getPrivateKeyboardEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_privateKeyboardKey) ?? false;
  }

  static Future<void> setPrivateKeyboardEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_privateKeyboardKey, value);
  }

  /// Feature: block screenshots and screen recording on EVERY screen of the
  /// app (chat list, settings …). Chats, stories and other private screens are
  /// ALWAYS blocked regardless of this switch — see ScreenshotGuardService.
  static const _blockScreenshotsEverywhereKey = 'block_screenshots_everywhere';

  static Future<bool> getBlockScreenshotsEverywhere() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_blockScreenshotsEverywhereKey) ?? false;
  }

  static Future<void> setBlockScreenshotsEverywhere(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_blockScreenshotsEverywhereKey, value);
  }

  /// Feature: hide the app preview in the recent-apps switcher (see
  /// ScreenshotGuardService.setRecentsPreviewHidden). ON by default — this
  /// is a security-first app, and this only ever ADDS protection (chats stay
  /// screenshot-blocked no matter what this is set to).
  static const _hideRecentsPreviewKey = 'hide_recents_preview';

  static Future<bool> getHideRecentsPreview() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hideRecentsPreviewKey) ?? true;
  }

  static Future<void> setHideRecentsPreview(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideRecentsPreviewKey, value);
  }
}
