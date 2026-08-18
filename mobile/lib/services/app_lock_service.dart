import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// BUGFIX: this used to store the app-lock PIN as plain text in secure
/// storage and compare it directly. flutter_secure_storage is encrypted at
/// rest, so this wasn't catastrophic, but it meant the raw PIN existed
/// on disk and would show up as-is in any storage inspection/backup tool
/// that gets access to it (e.g. a rooted device). It's now stored as a
/// salted SHA-256 hash, so the PIN itself is never persisted anywhere.
class AppLockService {
  static const _storage = FlutterSecureStorage();
  static const _pinHashKey = 'app_lock_pin_hash';
  static const _pinSaltKey = 'app_lock_pin_salt';
  static const _enabledKey = 'app_lock_enabled';
  static const _hintKey = 'app_lock_pin_hint';
  static final _sha256 = Sha256();

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: _enabledKey)) == 'true';
  }

  static String _randomSalt() {
    final rand = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
  }

  static Future<String> _hash(String pin, String salt) async {
    final hash = await _sha256.hash(utf8.encode('$salt:$pin'));
    return base64Encode(hash.bytes);
  }

  static Future<void> setPin(String pin, {String? hint}) async {
    final salt = _randomSalt();
    final hash = await _hash(pin, salt);
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(key: _pinHashKey, value: hash);
    await _storage.write(key: _enabledKey, value: 'true');
    if (hint != null && hint.trim().isNotEmpty) {
      await _storage.write(key: _hintKey, value: hint.trim());
    } else {
      await _storage.delete(key: _hintKey);
    }
  }

  static Future<String?> getHint() => _storage.read(key: _hintKey);

  static Future<void> disable() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _hintKey);
    await _storage.write(key: _enabledKey, value: 'false');
  }

  static Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _pinSaltKey);
    final stored = await _storage.read(key: _pinHashKey);
    if (salt == null || stored == null) return false;
    final candidate = await _hash(pin, salt);
    return candidate == stored;
  }

  static Future<void> resetAfterAccountVerification() => disable();
}
