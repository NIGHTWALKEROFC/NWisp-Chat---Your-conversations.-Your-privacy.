import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: quick replies / saved message templates. Save a message once,
/// reuse it anywhere text gets typed in this app — an ordinary chat's
/// composer or a broadcast list's composer (see BroadcastListService's own
/// doc comment for why broadcasts pair naturally with this: writing the
/// same announcement from scratch every time is exactly what this avoids).
/// Local-only, modeled on ChatFolderService's own SharedPreferences +
/// broadcast-stream pattern — a saved reply is exactly as sensitive as a
/// folder name, i.e. entirely up to what the person chooses to save in it.
class QuickReply {
  final String id;
  final String text;
  const QuickReply({required this.id, required this.text});

  Map<String, dynamic> toJson() => {'id': id, 'text': text};
  factory QuickReply.fromJson(Map<String, dynamic> j) => QuickReply(id: j['id'] as String, text: j['text'] as String);
}

class QuickReplyService {
  QuickReplyService._();

  static const _key = 'quick_replies_v1';
  static final _controller = StreamController<List<QuickReply>>.broadcast();
  static List<QuickReply>? _cache;

  static Future<List<QuickReply>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      _cache = [];
      return _cache!;
    }
    _cache = (jsonDecode(raw) as List).map((e) => QuickReply.fromJson(e as Map<String, dynamic>)).toList();
    return _cache!;
  }

  static Future<void> _save(List<QuickReply> replies) async {
    _cache = replies;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(replies.map((r) => r.toJson()).toList()));
    if (!_controller.isClosed) _controller.add(replies);
  }

  static Future<List<QuickReply>> getAll() => _load();

  static Stream<List<QuickReply>> watchAll() {
    _load().then((r) {
      if (!_controller.isClosed) _controller.add(r);
    });
    return _controller.stream;
  }

  static Future<void> add(String text) async {
    final replies = await _load();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await _save([...replies, QuickReply(id: id, text: text)]);
  }

  static Future<void> update(String id, String text) async {
    final replies = await _load();
    await _save([for (final r in replies) r.id == id ? QuickReply(id: id, text: text) : r]);
  }

  static Future<void> delete(String id) async {
    final replies = await _load();
    await _save(replies.where((r) => r.id != id).toList());
  }
}
