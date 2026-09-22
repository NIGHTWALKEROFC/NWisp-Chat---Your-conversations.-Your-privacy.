import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: chat wallpapers/themes per conversation. Pure visual
/// polish, no security implication at all — stored locally per device
/// (SharedPreferences, same as chat folders/settings), never synced, so
/// the other person in a 1:1 chat never sees or is affected by your
/// wallpaper choice. A small fixed set of presets rather than a custom
/// image picker, to keep this simple and avoid the extra storage/
/// permission surface a photo-backed wallpaper would need for what's
/// meant to be a lightweight cosmetic feature.
class ChatWallpaper {
  final String id;
  final String name;
  final List<Color> colors; // 1 color = solid; 2+ = gradient

  const ChatWallpaper({required this.id, required this.name, required this.colors});

  Decoration decoration() => BoxDecoration(
        gradient: colors.length > 1 ? LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        color: colors.length == 1 ? colors.first : null,
      );
}

const List<ChatWallpaper> kChatWallpapers = [
  ChatWallpaper(id: 'default', name: 'Default', colors: []),
  ChatWallpaper(id: 'slate', name: 'Slate', colors: [Color(0xFF1E2A38), Color(0xFF16202B)]),
  ChatWallpaper(id: 'sage', name: 'Sage', colors: [Color(0xFFE3EEE3), Color(0xFFCFE3CF)]),
  ChatWallpaper(id: 'sunset', name: 'Sunset', colors: [Color(0xFFFFE0B2), Color(0xFFFFCCBC)]),
  ChatWallpaper(id: 'ocean', name: 'Ocean', colors: [Color(0xFFB3E5FC), Color(0xFF81D4FA)]),
  ChatWallpaper(id: 'blush', name: 'Blush', colors: [Color(0xFFFCE4EC), Color(0xFFF8BBD0)]),
  ChatWallpaper(id: 'midnight', name: 'Midnight', colors: [Color(0xFF0D0D1A), Color(0xFF1A1A2E)]),
  ChatWallpaper(id: 'mono', name: 'Charcoal', colors: [Color(0xFF2B2B2B)]),
  // ---- more wallpapers: light ones ----
  ChatWallpaper(id: 'lavender', name: 'Lavender', colors: [Color(0xFFEDE7F6), Color(0xFFD1C4E9)]),
  ChatWallpaper(id: 'mint', name: 'Mint', colors: [Color(0xFFE0F2F1), Color(0xFFB2DFDB)]),
  ChatWallpaper(id: 'peach', name: 'Peach', colors: [Color(0xFFFFE5D9), Color(0xFFFFCDB2)]),
  ChatWallpaper(id: 'sky', name: 'Sky', colors: [Color(0xFFE3F2FD), Color(0xFFBBDEFB)]),
  ChatWallpaper(id: 'lemon', name: 'Lemon', colors: [Color(0xFFFFFDE7), Color(0xFFFFF59D)]),
  ChatWallpaper(id: 'lilac', name: 'Lilac', colors: [Color(0xFFF3E5F5), Color(0xFFE1BEE7)]),
  ChatWallpaper(id: 'coral', name: 'Coral', colors: [Color(0xFFFFEBEE), Color(0xFFFFCDD2)]),
  ChatWallpaper(id: 'sand', name: 'Sand', colors: [Color(0xFFF5EBDD), Color(0xFFE6D5B8)]),
  // ---- more wallpapers: dark ones ----
  ChatWallpaper(id: 'forest', name: 'Forest', colors: [Color(0xFF0F2A1F), Color(0xFF0A1F17)]),
  ChatWallpaper(id: 'ember', name: 'Ember', colors: [Color(0xFF2A1410), Color(0xFF3B1D14)]),
  ChatWallpaper(id: 'plum', name: 'Plum', colors: [Color(0xFF25122E), Color(0xFF170A1E)]),
  ChatWallpaper(id: 'deepsea', name: 'Deep sea', colors: [Color(0xFF071C2C), Color(0xFF0B2E45)]),
  ChatWallpaper(id: 'graphite', name: 'Graphite', colors: [Color(0xFF1C1C1E), Color(0xFF2C2C2E)]),
  ChatWallpaper(id: 'aurora', name: 'Aurora', colors: [Color(0xFF0F2027), Color(0xFF2C5364)]),
  ChatWallpaper(id: 'royal', name: 'Royal', colors: [Color(0xFF14183A), Color(0xFF2A1F5C)]),
  ChatWallpaper(id: 'rosewood', name: 'Rosewood', colors: [Color(0xFF2B1418), Color(0xFF3E1F26)]),
];

/// Whether a wallpaper is dark (used to pair themes sensibly and to label
/// the picker sections).
bool isDarkWallpaper(ChatWallpaper w) {
  if (w.colors.isEmpty) return false;
  return w.colors.first.computeLuminance() < 0.2;
}

class ChatWallpaperService {
  ChatWallpaperService._();
  static String _key(String conversationId) => 'chat_wallpaper_$conversationId';

  static Future<ChatWallpaper> getWallpaper(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key(conversationId));
    if (id == null) return kChatWallpapers.first;
    return kChatWallpapers.firstWhere((w) => w.id == id, orElse: () => kChatWallpapers.first);
  }

  static Future<void> setWallpaper(String conversationId, String wallpaperId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(conversationId), wallpaperId);
  }
}
