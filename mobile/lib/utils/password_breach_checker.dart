import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Feature: breached-password warning on signup, password reset, and
/// change-password.
///
/// Checks [password] against the free HaveIBeenPwned "Pwned Passwords"
/// API using k-anonymity: only the first 5 characters of the password's
/// SHA-1 hash are ever sent over the network — the full password, and
/// even the full hash, never leave the device. This is the exact
/// mechanism HIBP designed and documents for client-side use
/// (haveibeenpwned.com/API/v3#PwnedPasswords) — no API key, no account,
/// and genuinely free with no rate limit on this specific endpoint, so
/// there's no premium tier to accidentally depend on.
///
/// Returns how many times this exact password has appeared in known
/// breaches (0 if it hasn't been seen). Deliberately never throws on a
/// network hiccup — just returns 0 (fails open), so a flaky connection
/// can never block someone from signing up or resetting their password;
/// this is a warning, not a hard gate (see the "continue anyway" dialog
/// wherever this is used).
Future<int> checkPasswordBreachCount(String password) async {
  try {
    final hash = sha1.convert(utf8.encode(password)).toString().toUpperCase();
    final prefix = hash.substring(0, 5);
    final suffix = hash.substring(5);
    final res = await http
        .get(Uri.parse('https://api.pwnedpasswords.com/range/$prefix'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return 0;
    for (final line in const LineSplitter().convert(res.body)) {
      final parts = line.split(':');
      if (parts.length != 2) continue;
      if (parts[0].trim() == suffix) {
        return int.tryParse(parts[1].trim()) ?? 1;
      }
    }
    return 0;
  } catch (_) {
    return 0;
  }
}
