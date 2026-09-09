import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: chat hiding (WhatsApp-style). A person can hide specific 1:1
/// or group conversations behind a password or an emoji sequence they
/// choose — hidden chats vanish from the normal chat list entirely (not
/// moved to a separate "hidden" section visible from the main screen —
/// nothing on the home screen hints that anything is hidden at all,
/// matching the actual point of the feature). Entering the exact code
/// into the chat list's search bar reveals them for that session — see
/// ChatListScreen.
///
/// Same salted-SHA-256 storage pattern as AppLockService's PIN, for the
/// same reason: the code itself is never persisted anywhere, only a
/// hash of it.
///
/// Unlike AppLockService (deliberately device-wide, protects the device
/// regardless of which account is signed in), this is ACCOUNT-scoped —
/// see [clearAll], called from SessionService whenever a different
/// account signs in on this device, the same way PinService's
/// account-scoped state already is. Without that, a second account
/// signing in on the same device would inherit the first account's hide
/// code and hidden-chat list.
class ChatLockService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _codeHashKey = 'chat_lock_code_hash';
  static const _codeSaltKey = 'chat_lock_code_salt';
  static const _methodKey = 'chat_lock_method'; // 'password' | 'emoji'
  static const _hiddenIdsKey = 'chat_lock_hidden_ids';
  static const _lockedIdsKey = 'chat_lock_locked_ids';
  static final _sha256 = Sha256();

  static Future<bool> isSetUp() async {
    return (await _storage.read(key: _codeHashKey)) != null;
  }

  static Future<String?> getMethod() => _storage.read(key: _methodKey);

  static String _randomSalt() {
    final rand = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
  }

  static Future<String> _hash(String code, String salt) async {
    final hash = await _sha256.hash(utf8.encode('$salt:$code'));
    return base64Encode(hash.bytes);
  }

  /// [method] is 'password' or 'emoji' — purely cosmetic (which keyboard/
  /// input UI SetUpChatLockScreen shows next time), the actual check in
  /// [verify] is just a string comparison either way, so an emoji
  /// sequence and a typed password are handled identically under the
  /// hood.
  static Future<void> setUp({required String method, required String code}) async {
    final salt = _randomSalt();
    final hash = await _hash(code, salt);
    await _storage.write(key: _codeSaltKey, value: salt);
    await _storage.write(key: _codeHashKey, value: hash);
    await _storage.write(key: _methodKey, value: method);
  }

  static Future<bool> verify(String code) async {
    final salt = await _storage.read(key: _codeSaltKey);
    final stored = await _storage.read(key: _codeHashKey);
    if (salt == null || stored == null) return false;
    final candidate = await _hash(code, salt);
    return candidate == stored;
  }

  /// Turns chat hiding off entirely and un-hides every currently-hidden
  /// chat (they simply reappear in the normal chat list) — turning the
  /// feature off with chats still invisibly hidden and no way back in
  /// would be far worse than making them visible again.
  static Future<void> disable() async {
    await _storage.delete(key: _codeHashKey);
    await _storage.delete(key: _codeSaltKey);
    await _storage.delete(key: _methodKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hiddenIdsKey);
  }

  static Future<Set<String>> getHiddenConversationIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_hiddenIdsKey) ?? []).toSet();
  }

  static Future<void> setHidden(String conversationId, bool hidden) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_hiddenIdsKey) ?? []).toSet();
    if (hidden) {
      current.add(conversationId);
    } else {
      current.remove(conversationId);
    }
    await prefs.setStringList(_hiddenIdsKey, current.toList());
  }

  static Future<bool> isHidden(String conversationId) async {
    return (await getHiddenConversationIds()).contains(conversationId);
  }

  // ---------------------------------------------------------------------
  // Per-chat lock (feature: more 1:1 chat security settings)
  // ---------------------------------------------------------------------
  //
  // Distinct from chat hiding above: a locked chat stays fully visible
  // and findable in the normal chat list — this isn't about concealing
  // that it exists, it's about requiring your app PIN again to actually
  // open it, the same way a locked note or a locked app would.
  // Complementary rather than overlapping: hide a chat you don't want
  // anyone to know exists at all, lock one you're fine being SEEN but
  // don't want casually opened if someone picks up your unlocked phone.
  //
  // Deliberately reuses AppLockService's existing PIN (see PinScreen)
  // rather than inventing a second code — requires App Lock to already
  // be set up (ChatSettingsScreen enforces this, mirroring how the "Hide
  // this chat" toggle above requires chat hiding to be set up first).

  static Future<Set<String>> getLockedConversationIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_lockedIdsKey) ?? []).toSet();
  }

  static Future<void> setLocked(String conversationId, bool locked) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_lockedIdsKey) ?? []).toSet();
    if (locked) {
      current.add(conversationId);
    } else {
      current.remove(conversationId);
    }
    await prefs.setStringList(_lockedIdsKey, current.toList());
  }

  static Future<bool> isLocked(String conversationId) async {
    return (await getLockedConversationIds()).contains(conversationId);
  }

  /// See this class's own header comment — called from SessionService
  /// whenever a different account signs in on this device, the same way
  /// PinService.clearAll() already is.
  static Future<void> clearAll() async {
    await _storage.delete(key: _codeHashKey);
    await _storage.delete(key: _codeSaltKey);
    await _storage.delete(key: _methodKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hiddenIdsKey);
    await prefs.remove(_lockedIdsKey);
  }
}
