import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result of [ChatLockService.verifyAny] — tells the caller (FindUsersScreen)
/// whether a typed code matched the account-wide COMMON hide code, or one
/// specific chat's own CUSTOM code, so ChatListScreen only ever reveals
/// what that particular code is actually supposed to unlock.
class ChatUnlockResult {
  final bool isCommon;
  final String? conversationId; // set only when isCommon == false
  const ChatUnlockResult.common()
      : isCommon = true,
        conversationId = null;
  const ChatUnlockResult.custom(String this.conversationId) : isCommon = false;
}

/// Feature: chat hiding (WhatsApp-style), full redesign.
///
/// Two independent ways to hide a chat:
/// - COMMON code: one shared password/emoji sequence (as before). Any
///   number of chats can be hidden under it; typing it into the search
///   field reveals ALL of them at once.
/// - CUSTOM code: a chat can instead get its OWN distinct code, set from
///   that chat's own Chat Settings screen. Typing THAT code into the
///   search field reveals only that one chat — nothing else.
/// A given chat is hidden by at most one of these at a time.
///
/// Second factor (optional, OFF by default): a separate PIN — distinct
/// from AppLockService's whole-app PIN — that, once turned on, is
/// required AFTER a correct hide code before hidden chat content is
/// actually shown. Knowing the code alone then isn't enough.
///
/// Forgot-code recovery: turning hiding off used to be a single tap with
/// no verification at all — anyone holding the phone could switch it off
/// and see everything. Recovery now requires re-entering the account
/// password (see AuthService.reauthenticate, the same pattern
/// AppLockService's own "Forgot PIN?" already uses) and WIPES the local
/// content of whatever's being reset — the chat(s) come back to the
/// normal chat list empty, as if freshly started, rather than silently
/// exposing what was in them. Common and custom codes reset separately
/// (see [resetCommon]/[resetCustom]) so losing one doesn't force wiping
/// chats hidden under the other.
///
/// Same salted-SHA-256 storage pattern as AppLockService's PIN — no code
/// or PIN is ever persisted as plain text, only a hash of it.
///
/// Unlike AppLockService (deliberately device-wide), everything here is
/// ACCOUNT-scoped — see [clearAll], called from SessionService whenever a
/// different account signs in on this device, the same way it already was.
class ChatLockService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Common code
  static const _commonHashKey = 'chat_lock_common_hash';
  static const _commonSaltKey = 'chat_lock_common_salt';
  static const _commonMethodKey = 'chat_lock_common_method'; // 'password' | 'emoji'
  static const _commonHiddenIdsKey = 'chat_lock_hidden_common_ids'; // SharedPreferences

  // Custom per-chat codes — one JSON blob: { conversationId: {hash, salt, method} }
  static const _customEntriesKey = 'chat_lock_custom_entries';

  // Hidden-chats second-factor PIN (separate from AppLockService)
  static const _pinHashKey = 'chat_lock_pin_hash';
  static const _pinSaltKey = 'chat_lock_pin_salt';
  static const _pinEnabledKey = 'chat_lock_pin_enabled';

  static final _sha256 = Sha256();

  static String _randomSalt() {
    final rand = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rand.nextInt(256)));
  }

  static Future<String> _hash(String value, String salt) async {
    final hash = await _sha256.hash(utf8.encode('$salt:$value'));
    return base64Encode(hash.bytes);
  }

  // -----------------------------------------------------------------------
  // Common code
  // -----------------------------------------------------------------------

  static Future<bool> isCommonSetUp() async => (await _storage.read(key: _commonHashKey)) != null;

  static Future<String?> getCommonMethod() => _storage.read(key: _commonMethodKey);

  /// [method] is 'password' or 'emoji' — purely cosmetic (which keyboard/
  /// input UI the setup screen shows next time); verification is just a
  /// string comparison either way.
  static Future<void> setUpCommon({required String method, required String code}) async {
    final salt = _randomSalt();
    final hash = await _hash(code, salt);
    await _storage.write(key: _commonSaltKey, value: salt);
    await _storage.write(key: _commonHashKey, value: hash);
    await _storage.write(key: _commonMethodKey, value: method);
  }

  static Future<bool> _verifyCommon(String code) async {
    final salt = await _storage.read(key: _commonSaltKey);
    final stored = await _storage.read(key: _commonHashKey);
    if (salt == null || stored == null) return false;
    final candidate = await _hash(code, salt);
    return candidate == stored;
  }

  static Future<Set<String>> getCommonHiddenIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_commonHiddenIdsKey) ?? []).toSet();
  }

  /// Adds/removes a chat from the COMMON hidden set. Requires the common
  /// code to already be set up. This is the normal, everyday hide/unhide
  /// toggle for a chat that uses the common code — NOT the forgot-code
  /// recovery path (see [resetCommon] for that).
  static Future<void> setHiddenCommon(String conversationId, bool hidden) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_commonHiddenIdsKey) ?? []).toSet();
    if (hidden) {
      current.add(conversationId);
    } else {
      current.remove(conversationId);
    }
    await prefs.setStringList(_commonHiddenIdsKey, current.toList());
  }

  // -----------------------------------------------------------------------
  // Custom per-chat codes
  // -----------------------------------------------------------------------

  static Future<Map<String, dynamic>> _loadCustomEntries() async {
    final raw = await _storage.read(key: _customEntriesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveCustomEntries(Map<String, dynamic> entries) async {
    await _storage.write(key: _customEntriesKey, value: jsonEncode(entries));
  }

  static Future<bool> hasCustomCode(String conversationId) async {
    final entries = await _loadCustomEntries();
    return entries.containsKey(conversationId);
  }

  static Future<String?> getCustomMethod(String conversationId) async {
    final entries = await _loadCustomEntries();
    return (entries[conversationId] as Map?)?['method'] as String?;
  }

  /// Sets (or replaces) a chat's own custom code AND hides it — setting a
  /// custom code for a chat is what puts it in the hidden state under this
  /// design; there's no separate "hide" step after this.
  static Future<void> setUpCustom({
    required String conversationId,
    required String method,
    required String code,
  }) async {
    final salt = _randomSalt();
    final hash = await _hash(code, salt);
    final entries = await _loadCustomEntries();
    entries[conversationId] = {'hash': hash, 'salt': salt, 'method': method};
    await _saveCustomEntries(entries);
  }

  /// Normal, deliberate "stop hiding this chat" from inside a chat you
  /// already have open (you got there by unlocking it, so no extra
  /// verification is needed) — NOT the forgot-code recovery path. Content
  /// is left untouched; the chat just reappears in the normal list.
  static Future<void> removeCustomHiding(String conversationId) async {
    final entries = await _loadCustomEntries();
    entries.remove(conversationId);
    await _saveCustomEntries(entries);
  }

  static Future<Set<String>> getCustomHiddenIds() async {
    final entries = await _loadCustomEntries();
    return entries.keys.toSet();
  }

  // -----------------------------------------------------------------------
  // Combined lookups
  // -----------------------------------------------------------------------

  static Future<bool> isHidden(String conversationId) async {
    if ((await getCommonHiddenIds()).contains(conversationId)) return true;
    return hasCustomCode(conversationId);
  }

  /// Union of every hidden conversationId, common or custom — used by the
  /// normal (non-hidden) chat list view to filter them all out, and by
  /// main.dart to refuse opening a hidden chat from a tapped notification.
  static Future<Set<String>> getAllHiddenIds() async {
    final common = await getCommonHiddenIds();
    final custom = await getCustomHiddenIds();
    return {...common, ...custom};
  }

  /// Checked against the common code first, then every chat's own custom
  /// code. Returns null on no match. Only ever call this with input that's
  /// already been through the normal length/empty checks the search field
  /// does — see FindUsersScreen._onChanged.
  static Future<ChatUnlockResult?> verifyAny(String code) async {
    if (await _verifyCommon(code)) return const ChatUnlockResult.common();
    final entries = await _loadCustomEntries();
    for (final entry in entries.entries) {
      final data = entry.value as Map;
      final salt = data['salt'] as String?;
      final stored = data['hash'] as String?;
      if (salt == null || stored == null) continue;
      final candidate = await _hash(code, salt);
      if (candidate == stored) return ChatUnlockResult.custom(entry.key);
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // Hidden-chats second-factor PIN (separate from AppLockService)
  // -----------------------------------------------------------------------

  static Future<bool> isPinEnabled() async => (await _storage.read(key: _pinEnabledKey)) == 'true';

  static Future<void> setPin(String pin) async {
    final salt = _randomSalt();
    final hash = await _hash(pin, salt);
    await _storage.write(key: _pinSaltKey, value: salt);
    await _storage.write(key: _pinHashKey, value: hash);
    await _storage.write(key: _pinEnabledKey, value: 'true');
  }

  static Future<void> disablePin() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.write(key: _pinEnabledKey, value: 'false');
  }

  static Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _pinSaltKey);
    final stored = await _storage.read(key: _pinHashKey);
    if (salt == null || stored == null) return false;
    final candidate = await _hash(pin, salt);
    return candidate == stored;
  }

  // -----------------------------------------------------------------------
  // Forgot-code recovery — caller must already have password-reauthenticated
  // (see AuthService.reauthenticate) before calling either of these.
  // -----------------------------------------------------------------------

  /// Wipes out the COMMON code entirely and returns every conversationId
  /// that was hidden under it, so the caller can wipe each one's local
  /// message content (LocalMessageStore.clearConversation) before they
  /// reappear in the normal chat list — empty, as if freshly started.
  /// Custom-coded chats are untouched.
  static Future<List<String>> resetCommon() async {
    final ids = (await getCommonHiddenIds()).toList();
    await _storage.delete(key: _commonHashKey);
    await _storage.delete(key: _commonSaltKey);
    await _storage.delete(key: _commonMethodKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_commonHiddenIdsKey);
    return ids;
  }

  /// Wipes out ONE chat's custom code. The caller wipes that
  /// conversationId's local content the same way as [resetCommon] before
  /// it reappears. Every other custom-coded chat, and the common code, are
  /// untouched.
  static Future<void> resetCustom(String conversationId) async {
    final entries = await _loadCustomEntries();
    entries.remove(conversationId);
    await _saveCustomEntries(entries);
  }

  /// See this class's own header comment — called from SessionService
  /// whenever a different account signs in on this device.
  static Future<void> clearAll() async {
    await _storage.delete(key: _commonHashKey);
    await _storage.delete(key: _commonSaltKey);
    await _storage.delete(key: _commonMethodKey);
    await _storage.delete(key: _customEntriesKey);
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinEnabledKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_commonHiddenIdsKey);
  }
}
