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
];

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
