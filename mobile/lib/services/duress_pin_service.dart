import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'app_lock_service.dart';

/// Feature: duress/panic PIN. A SECOND PIN, completely independent of the
/// real app-lock PIN in AppLockService, that — when typed into the exact
/// same PIN screen — unlocks into a decoy section instead of the real
/// chat list. Same salted-SHA-256-hash storage approach as
/// AppLockService (see that file's doc comment for why: the PIN itself
/// is never persisted anywhere, only a salted hash of it), just under
/// its own separate keys so it can never collide with or overwrite the
/// real PIN's storage.
///
/// This can only ever be set up FROM WITHIN Settings, which itself sits
/// behind the real PIN once app lock is on — so setting a duress PIN at
/// all already implies the real one exists and was just entered
/// correctly. [setPin] additionally refuses to store a duress PIN that's
/// identical to the current real PIN (checked via AppLockService.verify)
/// — the two must always be distinguishable, or typing the real PIN
/// would ambiguously trigger the decoy too.
class DuressPinService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _pinHashKey = 'duress_pin_hash';
  static const _pinSaltKey = 'duress_pin_salt';
  static final _sha256 = Sha256();

  static Future<bool> isSet() async {
    return (await _storage.read(key: _pinHashKey)) != null;
  }

  static String _randomSalt() {
    final rand = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
  }

  static Future<String> _hash(String pin, String salt) async {
    final hash = await _sha256.hash(utf8.encode('$salt:$pin'));
    return base64Encode(hash.bytes);
  }

  /// Returns false (and stores nothing) if [pin] is identical to the
  /// real app-lock PIN — see class doc comment for why that's rejected
  /// rather than just discouraged.
  static Future<bool> setPin(String pin) async {
    if (await AppLockService.verify(pin)) return false;
    final salt = _randomSalt();
    final hash = await _hash(pin, salt);
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(key: _pinHashKey, value: hash);
    return true;
  }

  static Future<void> clear() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
  }

  static Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _pinSaltKey);
    final stored = await _storage.read(key: _pinHashKey);
    if (salt == null || stored == null) return false;
    final candidate = await _hash(pin, salt);
    return candidate == stored;
  }
}
