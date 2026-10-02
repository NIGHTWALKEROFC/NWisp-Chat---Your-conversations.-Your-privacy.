import 'package:flutter/widgets.dart';
import 'translations.dart';

/// Feature: app language.
///
/// How translation works here, in one paragraph: text in the app is written in
/// English in the code, and anything that should change with the language is
/// wrapped like `context.tr('Settings')`. That looks the English text up in the
/// table for the chosen language (l10n/translations.dart) and returns the
/// translation — or, if there isn't one, the English text itself, so nothing
/// is ever blank or broken. Because `tr` depends on the app's locale, screens
/// redraw by themselves the moment the language is changed.
///
/// Two levels of translation exist, and the language screen says which is which:
///  * "App text" — the languages in translations.dart, where the app's own
///    words (menus, settings, buttons) are translated.
///  * "Menus and dialogs" — every other language Flutter knows. The system
///    parts (date and time pickers, "OK/Cancel", copy/paste, text direction for
///    right-to-left languages) switch language, but the app's own screens stay
///    English until a translation table is added for that language.
///
/// Adding a language, or more text, is just adding lines to translations.dart.
class AppStrings {
  AppStrings._();

  /// Languages that have a translation table.
  static Set<String> get translatedLanguages => appTranslations.keys.toSet();

  static bool hasAppText(String languageCode) => appTranslations.containsKey(languageCode);

  /// The text for [english] in [locale], or [english] itself.
  static String translate(String english, Locale locale) {
    if (locale.languageCode == 'en') return english;
    // The tables are Simplified Chinese; Traditional is a different script.
    if (locale.languageCode == 'zh' && (locale.countryCode == 'TW' || locale.scriptCode == 'Hant')) return english;
    return appTranslations[locale.languageCode]?[english] ?? english;
  }
}

extension AppTranslate on BuildContext {
  /// `context.tr('Chats')` — the text in the app's current language.
  String tr(String english) => AppStrings.translate(english, Localizations.localeOf(this));
}
