import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings for NWisp's built-in private browser. All on-device.
class BrowserSettingsService {
  BrowserSettingsService._();
  static final instance = BrowserSettingsService._();

  static const _kEnabled = 'br_enabled';
  static const _kEngine = 'br_engine';
  static const _kTrackers = 'br_block_trackers';
  static const _kHttps = 'br_https_only';
  static const _kThirdCookies = 'br_block_3p_cookies';
  static const _kClearExit = 'br_clear_on_exit';
  static const _kJs = 'br_javascript';
  static const _kDesktop = 'br_desktop_mode';
  static const _kBlocked = 'br_blocked_count';
  static const _kHistory = 'br_save_history';

  /// Links open inside NWisp. On by default.
  final enabled = ValueNotifier<bool>(true);
  final searchEngine = ValueNotifier<String>('duckduckgo');
  final blockTrackers = ValueNotifier<bool>(true);
  final httpsOnly = ValueNotifier<bool>(true);
  final blockThirdPartyCookies = ValueNotifier<bool>(true);
  final clearOnExit = ValueNotifier<bool>(true);
  final javascript = ValueNotifier<bool>(true);
  final desktopMode = ValueNotifier<bool>(false);

  /// Remember visited pages (local, encrypted). Off by default.
  final saveHistory = ValueNotifier<bool>(false);
  int trackersBlockedTotal = 0;
  bool _loaded = false;

  static const engines = <String, (String, String)>{
    'duckduckgo': ('DuckDuckGo', 'https://duckduckgo.com/?q='),
    'brave': ('Brave Search', 'https://search.brave.com/search?q='),
    'startpage': ('Startpage', 'https://www.startpage.com/do/search?q='),
    'qwant': ('Qwant', 'https://www.qwant.com/?q='),
    'google': ('Google', 'https://www.google.com/search?q='),
  };

  String get searchPrefix => (engines[searchEngine.value] ?? engines['duckduckgo']!).$2;
  String get searchName => (engines[searchEngine.value] ?? engines['duckduckgo']!).$1;
  String get homeUrl => 'about:blank';

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    enabled.value = p.getBool(_kEnabled) ?? true;
    searchEngine.value = p.getString(_kEngine) ?? 'duckduckgo';
    blockTrackers.value = p.getBool(_kTrackers) ?? true;
    httpsOnly.value = p.getBool(_kHttps) ?? true;
    blockThirdPartyCookies.value = p.getBool(_kThirdCookies) ?? true;
    clearOnExit.value = p.getBool(_kClearExit) ?? true;
    javascript.value = p.getBool(_kJs) ?? true;
    desktopMode.value = p.getBool(_kDesktop) ?? false;
    saveHistory.value = p.getBool(_kHistory) ?? false;
    trackersBlockedTotal = p.getInt(_kBlocked) ?? 0;
    _loaded = true;
  }

  Future<void> _setBool(String key, ValueNotifier<bool> n, bool v) async {
    n.value = v;
    (await SharedPreferences.getInstance()).setBool(key, v);
  }

  Future<void> setEnabled(bool v) => _setBool(_kEnabled, enabled, v);
  Future<void> setBlockTrackers(bool v) => _setBool(_kTrackers, blockTrackers, v);
  Future<void> setHttpsOnly(bool v) => _setBool(_kHttps, httpsOnly, v);
  Future<void> setBlockThirdPartyCookies(bool v) => _setBool(_kThirdCookies, blockThirdPartyCookies, v);
  Future<void> setClearOnExit(bool v) => _setBool(_kClearExit, clearOnExit, v);
  Future<void> setJavascript(bool v) => _setBool(_kJs, javascript, v);
  Future<void> setDesktopMode(bool v) => _setBool(_kDesktop, desktopMode, v);
  Future<void> setSaveHistory(bool v) => _setBool(_kHistory, saveHistory, v);

  Future<void> setSearchEngine(String id) async {
    if (!engines.containsKey(id)) return;
    searchEngine.value = id;
    (await SharedPreferences.getInstance()).setString(_kEngine, id);
  }

  Future<void> addBlocked(int n) async {
    if (n <= 0) return;
    trackersBlockedTotal += n;
    (await SharedPreferences.getInstance()).setInt(_kBlocked, trackersBlockedTotal);
  }
}
