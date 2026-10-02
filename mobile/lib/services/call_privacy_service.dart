import 'package:shared_preferences/shared_preferences.dart';

/// Feature: "Protect IP address in calls" (Settings > Calls).
///
/// Normally a call connects the two phones directly, which means each side
/// can learn the other's network (IP) address. With this on, the call is
/// forced through a relay server (TURN) instead, so the other person only
/// ever sees the relay's address. The price is the same as in WhatsApp: a
/// little more delay and sometimes lower audio quality, because the audio
/// takes a detour. Off by default.
///
/// Only protects THIS phone's address — the other person's phone has its own
/// setting. And it only works when the app was built with a relay server (see
/// CallService.isTurnConfigured); without one, a relay-only call could never
/// connect, so the switch is disabled instead.
///
/// The value is read from a plain static field because the call code needs it
/// without waiting: [load] is called once at app start (main.dart).
class CallPrivacyService {
  CallPrivacyService._();

  static const _key = 'call_relay_only';

  static bool _relayOnly = false;
  static bool get relayOnly => _relayOnly;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _relayOnly = prefs.getBool(_key) ?? false;
  }

  static Future<void> setRelayOnly(bool value) async {
    _relayOnly = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
