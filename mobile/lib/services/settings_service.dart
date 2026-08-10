import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive app preferences that aren't tied to a specific screen.
/// The "stay signed in" flag is checked by AuthGate at app launch:
/// - true (default)  -> if Firebase already has a session, go straight to chats
/// - false            -> sign the user out on every app launch, always show Login
class SettingsService {
  static const _stayLoggedInKey = 'stay_signed_in';

  static Future<bool> getStayLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_stayLoggedInKey) ?? true;
  }

  static Future<void> setStayLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stayLoggedInKey, value);
  }
}
