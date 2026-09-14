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
}
