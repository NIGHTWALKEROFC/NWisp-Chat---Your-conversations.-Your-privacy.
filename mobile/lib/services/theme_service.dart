import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the user's chosen theme (Light / Dark / System) and text size, and
/// persists them locally so they survive app restarts. Not sensitive data,
/// so plain SharedPreferences is fine (unlike auth tokens, which stay in
/// flutter_secure_storage).
///
/// 2026-09-29: the new design is dark-first, so a fresh install (nothing
/// saved yet) now starts in Dark instead of System. Anyone who already
/// picked something keeps their choice. Also added the "Font size" setting
/// (Normal / Large) from the Appearance screen.
class ThemeService extends ChangeNotifier {
  static const _prefKey = 'theme_mode';
  static const _fontKey = 'font_scale';

  /// The two sizes offered in Appearance.
  static const double normalScale = 1.0;
  static const double largeScale = 1.15;

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  double _fontScale = normalScale;
  double get fontScale => _fontScale;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.dark, // nothing saved yet
    };
    _fontScale = prefs.getDouble(_fontKey) ?? normalScale;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, mode.name);
  }

  Future<void> setFontScale(double scale) async {
    _fontScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontKey, scale);
  }
}
