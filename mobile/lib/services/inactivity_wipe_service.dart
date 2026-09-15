import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_message_store.dart';
import 'settings_service.dart';

/// Feature: inactivity auto-wipe. Off by default, everywhere — matches
/// the user's own spec exactly: nothing here ever wipes anything unless
/// EITHER (a) the global default (Settings > Security > "Auto-wipe
/// inactive chats") is turned on, which then applies to every chat that
/// doesn't have its own override, OR (b) a specific chat's own override
/// (Chat settings > "Auto-wipe if inactive") is turned on for just that
/// one chat, regardless of the global setting. A chat-level override
/// always wins over the global default, in both directions — a chat
/// can opt OUT of an enabled global default just as easily as it can
/// opt IN while the default is off.
///
/// "Inactivity" is tracked PER CONVERSATION (when its chat screen was
/// last opened — see recordOpened, called from ChatDetailScreen/
/// GroupChatScreen's own initState), not "the whole app hasn't been
/// opened" — a per-chat model is what actually lets a per-chat override
/// mean anything. A "month" here is approximated as 30 days, for
/// simplicity, not a calendar month.
///
/// Like the "clear on exit" ephemeral mode this pairs conceptually
/// with, a wipe triggered here is 100% local — it only ever calls
/// LocalMessageStore.clearConversation on THIS device, never sends
/// anything to the relay, and never affects the other person's copy.
class InactivityWipeService {
  InactivityWipeService._();
  static const _lastOpenedKey = 'inactivity_wipe_last_opened_v1';
  static String _overrideKey(String conversationId) => 'inactivity_wipe_override_$conversationId';

  static Future<void> recordOpened(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastOpenedKey);
    final map = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(raw));
    map[conversationId] = DateTime.now().millisecondsSinceEpoch;
    await prefs.setString(_lastOpenedKey, jsonEncode(map));
  }

  /// null = no override — this chat just follows the global default.
  static Future<({bool enabled, int months})?> getChatOverride(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_overrideKey(conversationId));
    if (raw == null) return null;
    final map = Map<String, dynamic>.from(jsonDecode(raw));
    return (enabled: map['enabled'] as bool, months: map['months'] as int);
  }

  static Future<void> setChatOverride(String conversationId, bool enabled, int months) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_overrideKey(conversationId), jsonEncode({'enabled': enabled, 'months': months}));
  }

  static Future<void> clearChatOverride(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_overrideKey(conversationId));
  }

  /// Called once at app startup (see main.dart, right alongside the
  /// existing message-expiry purge) — checks every conversation this
  /// device has EVER recorded an open time for, against its effective
  /// threshold, and wipes any that have crossed it.
  static Future<void> sweep() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastOpenedKey);
    if (raw == null) return;
    final map = Map<String, dynamic>.from(jsonDecode(raw));
    final globalEnabled = await SettingsService.getInactivityWipeGlobalEnabled();
    final globalMonths = await SettingsService.getInactivityWipeGlobalMonths();
    final now = DateTime.now();
    final toForget = <String>[];
    for (final entry in map.entries) {
      final conversationId = entry.key;
      final lastOpened = DateTime.fromMillisecondsSinceEpoch(entry.value as int);
      final override = await getChatOverride(conversationId);
      final effectiveEnabled = override?.enabled ?? globalEnabled;
      final effectiveMonths = override?.months ?? globalMonths;
      if (!effectiveEnabled) continue;
      if (now.difference(lastOpened).inDays >= effectiveMonths * 30) {
        await LocalMessageStore.clearConversation(conversationId);
        toForget.add(conversationId);
      }
    }
    if (toForget.isNotEmpty) {
      for (final id in toForget) {
        map.remove(id);
      }
      await prefs.setString(_lastOpenedKey, jsonEncode(map));
    }
  }
}
