import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Feature: an optional lock for the "NWisp Chat Notifications" chat ONLY.
///
/// The chat lists your devices and locations, so it can be protected with its
/// own PIN (and fingerprint / face, if the phone has it). This is completely
/// separate from the app lock and from "Lock this chat" on normal chats: it
/// has its own PIN, it doesn't turn the app lock on, and nothing else in the
/// app asks for it.
///
/// Stored the same careful way the app lock stores its PIN: only a salted
/// SHA-256 hash, in encrypted secure storage, never the PIN itself. Everything
/// is keyed by account id, so a different account signing in on the same
/// phone doesn't inherit someone else's lock.
///
/// Biometrics are only ever a faster way past the same gate — the PIN stays
/// the real credential (and the fallback when the fingerprint changes or
/// fails), exactly as in AppLockService.
class SecurityChatLockService {
  SecurityChatLockService._();
  static final instance = SecurityChatLockService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static final _sha256 = Sha256();

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String _key(String name) => 'sec_chat_lock_${_uid ?? 'none'}_$name';

  /// Last known "is the lock on" answer, for widgets that can't await (the
  /// chat-list row). [changed] ticks whenever it may have changed.
  bool enabledCached = false;
  final ValueNotifier<int> changed = ValueNotifier(0);

  int _failures = 0;
  DateTime? _lockedUntil;

  Future<void> load() async {
    enabledCached = await isEnabled();
    changed.value++;
  }

  Future<bool> isEnabled() async => (await _storage.read(key: _key('enabled'))) == 'true';

  Future<bool> isBiometricEnabled() async => (await _storage.read(key: _key('biometric'))) == 'true';

  Future<void> setBiometricEnabled(bool value) async {
    await _storage.write(key: _key('biometric'), value: value ? 'true' : 'false');
    changed.value++;
  }

  /// Whether the one-time "Want to lock this chat?" offer was already shown
  /// (whatever the person answered). It's only ever offered once.
  Future<bool> hasBeenOffered() async => (await _storage.read(key: _key('offered'))) == 'true';

  Future<void> markOffered() => _storage.write(key: _key('offered'), value: 'true');

  static String _randomSalt() {
    final rand = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
  }

  static Future<String> _hash(String pin, String salt) async {
    final hash = await _sha256.hash(utf8.encode('$salt:$pin'));
    return base64Encode(hash.bytes);
  }

  /// Turns the lock on (or replaces the PIN if it's already on).
  Future<void> enable(String pin, {required bool biometric}) async {
    final salt = _randomSalt();
    await _storage.write(key: _key('salt'), value: salt);
    await _storage.write(key: _key('hash'), value: await _hash(pin, salt));
    await _storage.write(key: _key('biometric'), value: biometric ? 'true' : 'false');
    await _storage.write(key: _key('enabled'), value: 'true');
    enabledCached = true;
    changed.value++;
  }

  Future<void> disable() async {
    await _storage.delete(key: _key('enabled'));
    await _storage.delete(key: _key('hash'));
    await _storage.delete(key: _key('salt'));
    await _storage.delete(key: _key('biometric'));
    _failures = 0;
    _lockedUntil = null;
    enabledCached = false;
    changed.value++;
  }

  /// How long the PIN pad stays locked after too many wrong tries (null = not
  /// locked). Only kept in memory — it's a speed bump for someone guessing on
  /// an unlocked phone, not a security boundary.
  Duration? get lockoutRemaining {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  Future<bool> verifyPin(String pin) async {
    if (lockoutRemaining != null) return false;
    final salt = await _storage.read(key: _key('salt'));
    final stored = await _storage.read(key: _key('hash'));
    if (salt == null || stored == null) return false;
    final ok = await _hash(pin, salt) == stored;
    if (ok) {
      _failures = 0;
      return true;
    }
    _failures++;
    if (_failures >= 5) {
      _failures = 0;
      _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
    }
    return false;
  }
}
