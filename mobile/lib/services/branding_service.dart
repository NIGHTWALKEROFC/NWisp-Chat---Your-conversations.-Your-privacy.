import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Personalization that lives on THIS device only (not shared with other
/// users) — an accent color and an optional logo image shown on the login
/// screen and the settings header. Kept device-local on purpose: without an
/// admin role in this app yet, a Firestore-backed "global" version would let
/// any signed-in user re-brand the app for everyone.
class BrandingService extends ChangeNotifier {
  static const _colorKey = 'accent_color';
  static const _logoKey = 'custom_logo_url';

  Color? _accentColor;
  String? _logoUrl;

  Color? get accentColor => _accentColor;
  String? get logoUrl => _logoUrl;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_colorKey);
    _accentColor = colorValue != null ? Color(colorValue) : null;
    _logoUrl = prefs.getString(_logoKey);
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

  Future<void> setLogoUrl(String? url) async {
    _logoUrl = url;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (url == null) {
      await prefs.remove(_logoKey);
    } else {
      await prefs.setString(_logoKey, url);
    }
  }
}
