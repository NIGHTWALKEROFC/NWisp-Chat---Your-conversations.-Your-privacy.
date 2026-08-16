import 'package:shared_preferences/shared_preferences.dart';

/// Pinned messages per conversation, stored as an ORDERED list (not a set)
/// so the pinned banner can show "most recently pinned first" and let you
/// cycle through them — the way WhatsApp/Telegram do. Capped at 3 pins per
/// chat, the same cap WhatsApp uses.
class PinService {
  static const maxPinsPerChat = 3;

  static String _key(String conversationId) => 'pinned_msgs_$conversationId';

  static Future<List<String>> pinnedFor(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key(conversationId)) ?? [];
  }

  /// Pins/unpins [messageId]. Returns null on success, or a user-facing
  /// error message if the pin limit was hit.
  static Future<String?> togglePin(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toList();
    if (current.contains(messageId)) {
      current.remove(messageId);
    } else {
      if (current.length >= maxPinsPerChat) {
        return 'You can only pin up to $maxPinsPerChat messages in a chat — unpin one first.';
      }
      current.add(messageId);
    }
    await prefs.setStringList(_key(conversationId), current);
    return null;
  }

  static Future<void> unpin(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toList();
    current.remove(messageId);
    await prefs.setStringList(_key(conversationId), current);
  }

  static Future<void> clear(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(conversationId));
  }

  /// Wipes pinned-message state for EVERY conversation on this device —
  /// used when a different account signs in on this device (see
  /// SessionService), since old pin references would otherwise point at
  /// another account's messages.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('pinned_msgs_')).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
