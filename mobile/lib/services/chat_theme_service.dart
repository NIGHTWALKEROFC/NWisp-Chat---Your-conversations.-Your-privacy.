import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_wallpaper_service.dart';

/// A bubble / accent colour for ONE chat. It recolours that chat's sent
/// bubbles, send button and links (see ChatThemeScope). Purely cosmetic and
/// stored on this phone only — the other person never sees it.
class ChatAccent {
  final String id;
  final String name;
  final Color color;
  const ChatAccent(this.id, this.name, this.color);
}

const List<ChatAccent> kChatAccents = [
  ChatAccent('ocean', 'Ocean', Color(0xFF0288D1)),
  ChatAccent('emerald', 'Emerald', Color(0xFF2E7D32)),
  ChatAccent('rose', 'Rose', Color(0xFFD81B60)),
  ChatAccent('violet', 'Violet', Color(0xFF7E57C2)),
  ChatAccent('amber', 'Amber', Color(0xFFFB8C00)),
  ChatAccent('teal', 'Teal', Color(0xFF00897B)),
  ChatAccent('crimson', 'Crimson', Color(0xFFC62828)),
  ChatAccent('indigo', 'Indigo', Color(0xFF3949AB)),
  ChatAccent('slate', 'Slate', Color(0xFF546E7A)),
  ChatAccent('orchid', 'Orchid', Color(0xFFAB47BC)),
  ChatAccent('lime', 'Lime', Color(0xFF7CB342)),
  ChatAccent('coffee', 'Coffee', Color(0xFF6D4C41)),
  ChatAccent('sunset', 'Sunset', Color(0xFFF4511E)),
  ChatAccent('sky', 'Sky', Color(0xFF29B6F6)),
];

/// A ready-made look: one wallpaper + one accent colour, applied together.
class ChatThemeBundle {
  final String id;
  final String name;
  final String wallpaperId;
  final String accentId;
  const ChatThemeBundle(this.id, this.name, this.wallpaperId, this.accentId);
}

const List<ChatThemeBundle> kChatThemeBundles = [
  ChatThemeBundle('aurora', 'Aurora', 'aurora', 'teal'),
  ChatThemeBundle('forest_night', 'Forest night', 'forest', 'emerald'),
  ChatThemeBundle('ember', 'Ember', 'ember', 'sunset'),
  ChatThemeBundle('royal', 'Royal', 'royal', 'violet'),
  ChatThemeBundle('deep_sea', 'Deep sea', 'deepsea', 'ocean'),
  ChatThemeBundle('plum', 'Plum', 'plum', 'orchid'),
  ChatThemeBundle('graphite', 'Graphite', 'graphite', 'slate'),
  ChatThemeBundle('rosewood', 'Rosewood', 'rosewood', 'rose'),
  ChatThemeBundle('lavender', 'Lavender', 'lavender', 'violet'),
  ChatThemeBundle('mint_fresh', 'Mint fresh', 'mint', 'teal'),
  ChatThemeBundle('peach', 'Peach', 'peach', 'sunset'),
  ChatThemeBundle('sky_day', 'Sky day', 'sky', 'ocean'),
  ChatThemeBundle('lemon', 'Lemon', 'lemon', 'amber'),
  ChatThemeBundle('sand', 'Sand', 'sand', 'coffee'),
  ChatThemeBundle('blush', 'Blush', 'blush', 'rose'),
];

class ChatThemeService {
  ChatThemeService._();

  /// Bumped whenever any chat's accent changes, so an open chat recolours
  /// straight away.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static String _key(String conversationId) => 'chat_accent_$conversationId';

  /// The chosen accent for this chat, or null = the app's normal colour.
  static Future<ChatAccent?> getAccent(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key(conversationId));
    if (id == null) return null;
    for (final a in kChatAccents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Pass null to go back to the app's normal colour.
  static Future<void> setAccent(String conversationId, String? accentId) async {
    final prefs = await SharedPreferences.getInstance();
    if (accentId == null) {
      await prefs.remove(_key(conversationId));
    } else {
      await prefs.setString(_key(conversationId), accentId);
    }
    changes.value++;
  }

  static Future<void> applyBundle(String conversationId, ChatThemeBundle bundle) async {
    await ChatWallpaperService.setWallpaper(conversationId, bundle.wallpaperId);
    await setAccent(conversationId, bundle.accentId);
  }

  /// Back to the plain look: default wallpaper, app colour.
  static Future<void> reset(String conversationId) async {
    await ChatWallpaperService.setWallpaper(conversationId, 'default');
    await setAccent(conversationId, null);
  }
}
