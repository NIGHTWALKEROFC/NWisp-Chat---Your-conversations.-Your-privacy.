import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: mute by keyword. IMPORTANT ARCHITECTURAL LIMIT, please read
/// before wiring this up anywhere else: this app's relay never has
/// plaintext (that's the whole zero-knowledge design — see
/// message_relay_service.dart), so the push notification itself NEVER
/// contains real message text, only a fixed generic string like "Sent
/// you a message". There is nothing in a push notification a keyword
/// could ever match against.
///
/// What this DOES do: the moment a message is actually decrypted and
/// stored on this device — which only happens while the app's Dart
/// engine is alive (foreground, or backgrounded-but-not-killed) — its
/// real text becomes available locally. main.dart's foreground FCM
/// handler uses that to check the just-arrived message against these
/// keyword lists before showing the local notification for it (see
/// LocalMessageStore.getLatestMessage). While the app is fully killed
/// or suspended by the OS, the system shows FCM's own generic
/// notification automatically, with no app code involved at all — that
/// one can't be keyword-filtered, structurally, no matter what. This
/// mirrors the SAME reasoning already given for why full multi-device
/// login isn't a simple toggle in this app: real limits from the
/// zero-knowledge design, explained rather than silently worked around.
///
/// Two keyword lists, both local-only, both case-insensitive substring
/// matches: a GLOBAL list (applies everywhere) and a per-conversation
/// list (only for that one chat/group) — same global+per-chat shape as
/// notification-privacy and read-receipt overrides elsewhere in this
/// app. A message matching EITHER list is muted.
class KeywordMuteService {
  KeywordMuteService._();
  static const _globalKey = 'keyword_mute_global';
  static String _chatKey(String conversationId) => 'keyword_mute_chat_$conversationId';

  static Future<List<String>> getGlobalKeywords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_globalKey);
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw));
  }

  static Future<void> setGlobalKeywords(List<String> keywords) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_globalKey, jsonEncode(keywords));
  }

  static Future<List<String>> getChatKeywords(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chatKey(conversationId));
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw));
  }

  static Future<void> setChatKeywords(String conversationId, List<String> keywords) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chatKey(conversationId), jsonEncode(keywords));
  }

  /// True if [text] contains any global OR any per-chat muted keyword
  /// (case-insensitive substring match — deliberately simple, no regex/
  /// whole-word matching, so "meet" also catches "meeting" the way most
  /// people expect a basic keyword mute to behave).
  static Future<bool> isMuted(String conversationId, String text) async {
    final lower = text.toLowerCase();
    final global = await getGlobalKeywords();
    final chat = await getChatKeywords(conversationId);
    for (final kw in [...global, ...chat]) {
      if (kw.trim().isNotEmpty && lower.contains(kw.trim().toLowerCase())) return true;
    }
    return false;
  }
}
