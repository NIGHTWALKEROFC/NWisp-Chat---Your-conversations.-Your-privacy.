import 'package:shared_preferences/shared_preferences.dart';

class PinService {
  static String _key(String conversationId) => 'pinned_msgs_$conversationId';

  static Future<Set<String>> pinnedFor(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key(conversationId)) ?? []).toSet();
  }

  static Future<void> togglePin(String conversationId, String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key(conversationId)) ?? []).toSet();
    if (current.contains(messageId)) {
      current.remove(messageId);
    } else {
      current.add(messageId);
    }
    await prefs.setStringList(_key(conversationId), current.toList());
  }

  static Future<void> clear(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(conversationId));
  }
}
