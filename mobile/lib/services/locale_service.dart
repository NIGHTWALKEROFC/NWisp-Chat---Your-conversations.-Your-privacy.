import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/languages.dart';

/// The language the person picked in Settings > App language, kept on this
/// phone. Null means "use the phone's own language" — the default. Provided to
/// the whole app in main.dart; MaterialApp's `locale` follows it, so changing
/// it switches the language everywhere at once.
class LocaleService extends ChangeNotifier {
  static const _key = 'app_language';

  String? _code;
  String? get code => _code;

  /// The Locale to give MaterialApp (null = follow the phone).
  Locale? get locale => AppLanguages.byCode(_code)?.locale;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    // A saved language this Flutter version doesn't support is ignored.
    _code = AppLanguages.byCode(saved) == null ? null : saved;
    notifyListeners();
  }

  /// [code] null = back to the phone's language.
  Future<void> setLanguage(String? code) async {
    _code = code;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (code == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, code);
    }
  }
}
