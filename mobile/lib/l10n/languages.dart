import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// One language in the picker.
class AppLanguage {
  /// "hi", or "zh_TW" when a region matters. Stored as the setting.
  final String code;
  final String native;
  final String english;
  const AppLanguage(this.code, this.native, this.english);

  Locale get locale {
    final parts = code.split('_');
    return parts.length == 2 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
  }
}

/// Every language the app can switch to: all the ones Flutter has built-in
/// system translations for (date pickers, dialog buttons, text direction...).
/// The list below is filtered at runtime against what this Flutter version
/// really supports, so an entry that isn't supported simply doesn't appear.
class AppLanguages {
  AppLanguages._();

  static const _all = <AppLanguage>[
    AppLanguage('af', 'Afrikaans', 'Afrikaans'),
    AppLanguage('am', 'አማርኛ', 'Amharic'),
    AppLanguage('ar', 'العربية', 'Arabic'),
    AppLanguage('as', 'অসমীয়া', 'Assamese'),
    AppLanguage('az', 'Azərbaycanca', 'Azerbaijani'),
    AppLanguage('be', 'Беларуская', 'Belarusian'),
    AppLanguage('bg', 'Български', 'Bulgarian'),
    AppLanguage('bn', 'বাংলা', 'Bengali'),
    AppLanguage('bs', 'Bosanski', 'Bosnian'),
    AppLanguage('ca', 'Català', 'Catalan'),
    AppLanguage('cs', 'Čeština', 'Czech'),
    AppLanguage('cy', 'Cymraeg', 'Welsh'),
    AppLanguage('da', 'Dansk', 'Danish'),
    AppLanguage('de', 'Deutsch', 'German'),
    AppLanguage('el', 'Ελληνικά', 'Greek'),
    AppLanguage('en', 'English', 'English'),
    AppLanguage('es', 'Español', 'Spanish'),
    AppLanguage('et', 'Eesti', 'Estonian'),
    AppLanguage('eu', 'Euskara', 'Basque'),
    AppLanguage('fa', 'فارسی', 'Persian'),
    AppLanguage('fi', 'Suomi', 'Finnish'),
    AppLanguage('fil', 'Filipino', 'Filipino'),
    AppLanguage('fr', 'Français', 'French'),
    AppLanguage('gl', 'Galego', 'Galician'),
    AppLanguage('gsw', 'Schwiizerdütsch', 'Swiss German'),
    AppLanguage('gu', 'ગુજરાતી', 'Gujarati'),
    AppLanguage('he', 'עברית', 'Hebrew'),
    AppLanguage('hi', 'हिन्दी', 'Hindi'),
    AppLanguage('hr', 'Hrvatski', 'Croatian'),
    AppLanguage('hu', 'Magyar', 'Hungarian'),
    AppLanguage('hy', 'Հայերեն', 'Armenian'),
    AppLanguage('id', 'Bahasa Indonesia', 'Indonesian'),
    AppLanguage('is', 'Íslenska', 'Icelandic'),
    AppLanguage('it', 'Italiano', 'Italian'),
    AppLanguage('ja', '日本語', 'Japanese'),
    AppLanguage('ka', 'ქართული', 'Georgian'),
    AppLanguage('kk', 'Қазақша', 'Kazakh'),
    AppLanguage('km', 'ខ្មែរ', 'Khmer'),
    AppLanguage('kn', 'ಕನ್ನಡ', 'Kannada'),
    AppLanguage('ko', '한국어', 'Korean'),
    AppLanguage('ky', 'Кыргызча', 'Kyrgyz'),
    AppLanguage('lo', 'ລາວ', 'Lao'),
    AppLanguage('lt', 'Lietuvių', 'Lithuanian'),
    AppLanguage('lv', 'Latviešu', 'Latvian'),
    AppLanguage('mk', 'Македонски', 'Macedonian'),
    AppLanguage('ml', 'മലയാളം', 'Malayalam'),
    AppLanguage('mn', 'Монгол', 'Mongolian'),
    AppLanguage('mr', 'मराठी', 'Marathi'),
    AppLanguage('ms', 'Bahasa Melayu', 'Malay'),
    AppLanguage('my', 'မြန်မာ', 'Burmese'),
    AppLanguage('nb', 'Norsk bokmål', 'Norwegian'),
    AppLanguage('ne', 'नेपाली', 'Nepali'),
    AppLanguage('nl', 'Nederlands', 'Dutch'),
    AppLanguage('or', 'ଓଡ଼ିଆ', 'Odia'),
    AppLanguage('pa', 'ਪੰਜਾਬੀ', 'Punjabi'),
    AppLanguage('pl', 'Polski', 'Polish'),
    AppLanguage('ps', 'پښتو', 'Pashto'),
    AppLanguage('pt', 'Português', 'Portuguese'),
    AppLanguage('ro', 'Română', 'Romanian'),
    AppLanguage('ru', 'Русский', 'Russian'),
    AppLanguage('si', 'සිංහල', 'Sinhala'),
    AppLanguage('sk', 'Slovenčina', 'Slovak'),
    AppLanguage('sl', 'Slovenščina', 'Slovenian'),
    AppLanguage('sq', 'Shqip', 'Albanian'),
    AppLanguage('sr', 'Српски', 'Serbian'),
    AppLanguage('sv', 'Svenska', 'Swedish'),
    AppLanguage('sw', 'Kiswahili', 'Swahili'),
    AppLanguage('ta', 'தமிழ்', 'Tamil'),
    AppLanguage('te', 'తెలుగు', 'Telugu'),
    AppLanguage('th', 'ไทย', 'Thai'),
    AppLanguage('tl', 'Tagalog', 'Tagalog'),
    AppLanguage('tr', 'Türkçe', 'Turkish'),
    AppLanguage('uk', 'Українська', 'Ukrainian'),
    AppLanguage('ur', 'اردو', 'Urdu'),
    AppLanguage('uz', 'Oʻzbekcha', 'Uzbek'),
    AppLanguage('vi', 'Tiếng Việt', 'Vietnamese'),
    AppLanguage('zh', '简体中文', 'Chinese (Simplified)'),
    AppLanguage('zh_TW', '繁體中文', 'Chinese (Traditional)'),
    AppLanguage('zu', 'isiZulu', 'Zulu'),
  ];

  /// The languages to offer, in the order of the list above (by language code).
  static final List<AppLanguage> available = [
    for (final l in _all)
      if (GlobalMaterialLocalizations.delegate.isSupported(l.locale)) l,
  ];

  /// What MaterialApp gets as `supportedLocales`. English goes first on
  /// purpose: when a phone's own language isn't supported, Flutter falls back
  /// to the FIRST entry, and that should be English, not Afrikaans.
  static List<Locale> get supportedLocales => [
        const Locale('en'),
        for (final l in available)
          if (l.code != 'en') l.locale,
      ];

  static AppLanguage? byCode(String? code) {
    if (code == null) return null;
    for (final l in available) {
      if (l.code == code) return l;
    }
    return null;
  }
}
