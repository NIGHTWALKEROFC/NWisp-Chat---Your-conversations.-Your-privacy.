import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_wallpaper_service.dart';

/// Feature: home screen background. Deliberately reuses ChatWallpaper /
/// kChatWallpapers from chat_wallpaper_service.dart rather than a separate
/// preset list — same presets everywhere keeps the app feeling like one
/// coherent thing instead of two different theming systems, and it means
/// "more themes" added there (see that file) apply here too automatically.
/// One background for the whole home screen — there's no per-chat concept
/// here the way there is for chat wallpapers, since this is the screen
/// that LISTS all your chats, not one particular chat.
class HomeBackgroundService {
  HomeBackgroundService._();

  static const _key = 'home_background';
  static const _customPrefix = 'custom:';

  /// Bumped whenever the background changes, so the home screen (see
  /// _HomeBackgroundView in chat_list_screen.dart) can refresh live —
  /// same pattern as ChatThemeService.changes.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<ChatWallpaper> getBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored == null) return kChatWallpapers.first; // 'default' — no background, plain theme surface
    if (stored.startsWith(_customPrefix)) {
      final path = stored.substring(_customPrefix.length);
      return ChatWallpaper(id: 'custom', name: 'Custom photo', colors: const [], imagePath: path);
    }
    return kChatWallpapers.firstWhere((w) => w.id == stored, orElse: () => kChatWallpapers.first);
  }

  static Future<void> setBackground(String wallpaperId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, wallpaperId);
    changes.value++;
  }

  static Future<void> setCustomBackground(String imagePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, '$_customPrefix$imagePath');
    changes.value++;
  }

  /// Same idea as ChatWallpaperService.persistCustomImage — copies the
  /// picked photo into this app's own storage so it survives the OS
  /// clearing out temp/cache files later.
  static Future<String> persistCustomImage(File source) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/chat_wallpapers');
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = source.path.contains('.') ? source.path.split('.').last : 'jpg';
    final dest = File('${dir.path}/home_background.$ext');
    await source.copy(dest.path);
    return dest.path;
  }
}
