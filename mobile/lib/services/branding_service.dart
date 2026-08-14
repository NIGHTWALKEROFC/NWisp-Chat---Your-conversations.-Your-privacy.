import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Personalization that lives on THIS device only — an accent color shown
/// across the app's theme. Kept device-local on purpose.
class BrandingService extends ChangeNotifier {
  static const _colorKey = 'accent_color';

  Color? _accentColor;

  Color? get accentColor => _accentColor;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_colorKey);
    _accentColor = colorValue != null ? Color(colorValue) : null;
    notifyListeners();
  }

  Future<void> setAccentColor(Color? color) async {
    _accentColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_colorKey);
    } else {
      await prefs.setInt(_colorKey, color.toARGB32());
    }
  }
}
