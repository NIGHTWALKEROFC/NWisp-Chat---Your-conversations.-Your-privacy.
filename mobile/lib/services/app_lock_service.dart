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
///
/// BUGFIX 2: `_storage` used to be built with NO AndroidOptions, which
/// defaults to flutter_secure_storage's older, per-value Keystore-key
/// encryption path (`encryptedSharedPreferences: false`). That legacy path
/// is documented to be unreliable on stock Android across a real process
/// kill on many OEM skins (Samsung/MIUI/etc. more aggressively invalidate
/// its Keystore key under Doze/App Standby) — values written during a
/// session can simply fail to read back as null after the app is swiped
/// away from Recents and cold-started again, which reads exactly like
/// "app lock silently turned itself off." SecureStorageService (right next
/// to this file) already opts into the newer, more robust
/// EncryptedSharedPreferences-backed path via `encryptedSharedPreferences:
/// true` — this now matches that, so the PIN/enabled flag survive a real
/// app kill the same way the rest of the app's secure data already does.
class AppLockService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _pinHashKey = 'app_lock_pin_hash';
  static const _pinSaltKey = 'app_lock_pin_salt';
  static const _enabledKey = 'app_lock_enabled';
  static const _hintKey = 'app_lock_pin_hint';
  // Feature: biometric unlock for the app-wide PIN — see
  // BiometricUnlockService for the actual local_auth calls. This flag
  // just records whether the person has opted in; the PIN itself stays
  // the source of truth and the only thing ever stored/verified here —
  // biometric unlock is purely an alternate, faster way to pass the SAME
  // gate, never a replacement credential of its own.
  static const _biometricEnabledKey = 'app_lock_biometric_enabled';
  // Feature: auto-lock on idle. Minutes of no touch input before the app
  // re-locks itself even while it's still in the FOREGROUND — separate
  // from the existing re-lock-on-background behavior in auth_gate.dart,
  // which only fires when the app is actually paused/backgrounded. Null
  // (nothing stored) means "off" — the app stays unlocked indefinitely
  // while in the foreground, same as before this feature existed.
  static const _idleTimeoutKey = 'app_lock_idle_timeout_minutes';
  // Feature: lock timing when you LEAVE the app. Minutes the app may sit in
  // the background before it asks for the PIN again on return. 0 (or
  // nothing stored) = "Immediately", which is exactly how the app behaved
  // before this setting existed, so nobody's security silently loosens.
  static const _backgroundGraceKey = 'app_lock_background_grace_minutes';
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

  static Future<bool> isBiometricEnabled() async {
    return (await _storage.read(key: _biometricEnabledKey)) == 'true';
  }

  /// Only meaningful while a PIN is set — the PIN screen/settings UI is
  /// responsible for only exposing this toggle when [isEnabled] is
  /// already true, and for turning it back off itself if the PIN is ever
  /// disabled (see [disable] below, which also clears this).
  static Future<void> setBiometricEnabled(bool value) async {
    await _storage.write(key: _biometricEnabledKey, value: value ? 'true' : 'false');
  }

  static Future<void> disable() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _hintKey);
    await _storage.delete(key: _biometricEnabledKey);
    await _storage.delete(key: _idleTimeoutKey);
    await _storage.delete(key: _backgroundGraceKey);
    await _storage.write(key: _enabledKey, value: 'false');
  }

  /// Null = off (default — matches the app's behavior before this
  /// feature existed: stays unlocked indefinitely in the foreground).
  /// Otherwise the number of minutes of no touch input before AuthGate's
  /// _LockGate re-locks — see that file for the actual idle timer.
  static Future<int?> getIdleTimeoutMinutes() async {
    final raw = await _storage.read(key: _idleTimeoutKey);
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  static Future<void> setIdleTimeoutMinutes(int? minutes) async {
    if (minutes == null) {
      await _storage.delete(key: _idleTimeoutKey);
    } else {
      await _storage.write(key: _idleTimeoutKey, value: minutes.toString());
    }
  }

  /// Feature: lock timing when leaving the app. 0 = lock immediately (the
  /// default and the strictest); otherwise the number of minutes the app can
  /// stay in the background before it needs the PIN again. Enforced in
  /// AuthGate's _LockGate when the app comes back to the foreground.
  static Future<int> getBackgroundGraceMinutes() async {
    final raw = await _storage.read(key: _backgroundGraceKey);
    final parsed = raw == null ? null : int.tryParse(raw);
    return (parsed == null || parsed < 0) ? 0 : parsed;
  }

  static Future<void> setBackgroundGraceMinutes(int minutes) async {
    if (minutes <= 0) {
      await _storage.delete(key: _backgroundGraceKey);
    } else {
      await _storage.write(key: _backgroundGraceKey, value: minutes.toString());
    }
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
