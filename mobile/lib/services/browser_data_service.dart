import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BrowserEntry {
  final String title;
  final String url;
  final int ms;
  const BrowserEntry({required this.title, required this.url, required this.ms});
  Map<String, dynamic> toJson() => {'t': title, 'u': url, 'ms': ms};
  factory BrowserEntry.fromJson(Map<String, dynamic> j) =>
      BrowserEntry(title: (j['t'] as String?) ?? '', url: j['u'] as String, ms: (j['ms'] as int?) ?? 0);
}

/// Bookmarks and (optional) history for the private browser. Both live only
/// on this phone, in encrypted storage. History is off unless the person
/// turns it on in Browser settings, and it is capped at 200 entries.
class BrowserDataService {
  BrowserDataService._();
  static final instance = BrowserDataService._();

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _kBookmarks = 'br_bookmarks_v1';
  static const _kHistory = 'br_history_v1';
  static const _maxHistory = 200;
  static const _maxBookmarks = 200;

  /// Bumped whenever bookmarks change, so screens can redraw.
  final ValueNotifier<int> bookmarksTick = ValueNotifier<int>(0);

  List<BrowserEntry>? _bookmarks;
  List<BrowserEntry>? _history;

  Future<List<BrowserEntry>> _read(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => BrowserEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(String key, List<BrowserEntry> list) =>
      _storage.write(key: key, value: jsonEncode(list.map((e) => e.toJson()).toList()));

  Future<List<BrowserEntry>> bookmarks() async => _bookmarks ??= await _read(_kBookmarks);
  Future<List<BrowserEntry>> history() async => _history ??= await _read(_kHistory);

  Future<bool> isBookmarked(String url) async => (await bookmarks()).any((b) => b.url == url);

  /// Adds the page, or removes it if it was already bookmarked. Returns the
  /// new state (true = now bookmarked).
  Future<bool> toggleBookmark(String url, String title) async {
    final list = await bookmarks();
    final existing = list.indexWhere((b) => b.url == url);
    bool now;
    if (existing >= 0) {
      list.removeAt(existing);
      now = false;
    } else {
      list.insert(0, BrowserEntry(title: title.isEmpty ? url : title, url: url, ms: DateTime.now().millisecondsSinceEpoch));
      if (list.length > _maxBookmarks) list.removeRange(_maxBookmarks, list.length);
      now = true;
    }
    await _write(_kBookmarks, list);
    bookmarksTick.value++;
    return now;
  }

  Future<void> removeBookmark(String url) async {
    final list = await bookmarks();
    list.removeWhere((b) => b.url == url);
    await _write(_kBookmarks, list);
    bookmarksTick.value++;
  }

  Future<void> addHistory(String url, String title) async {
    final list = await history();
    if (list.isNotEmpty && list.first.url == url) return;
    list.insert(0, BrowserEntry(title: title.isEmpty ? url : title, url: url, ms: DateTime.now().millisecondsSinceEpoch));
    if (list.length > _maxHistory) list.removeRange(_maxHistory, list.length);
    await _write(_kHistory, list);
  }

  Future<void> removeHistory(String url, int ms) async {
    final list = await history();
    list.removeWhere((h) => h.url == url && h.ms == ms);
    await _write(_kHistory, list);
  }

  Future<void> clearHistory() async {
    _history = [];
    await _storage.delete(key: _kHistory);
  }
}
