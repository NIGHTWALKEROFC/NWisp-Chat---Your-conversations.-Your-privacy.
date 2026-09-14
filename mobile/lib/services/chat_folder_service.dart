import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: chat folders/categories. Purely local organization — like
/// SettingsService, this is a device preference, not synced anywhere
/// (there's nothing sensitive in a folder name or which chats are in it,
/// but it's also genuinely personal-to-this-device the way "muted" or
/// "archived" already are, so SharedPreferences fits the same way it
/// does for those). A conversationId can be in any number of folders at
/// once — folders are just named filters over the same chat list, not a
/// place each chat exclusively "lives".
class ChatFolder {
  final String id;
  final String name;
  final List<String> conversationIds;

  const ChatFolder({required this.id, required this.name, required this.conversationIds});

  ChatFolder copyWith({String? name, List<String>? conversationIds}) =>
      ChatFolder(id: id, name: name ?? this.name, conversationIds: conversationIds ?? this.conversationIds);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'conversationIds': conversationIds};

  factory ChatFolder.fromJson(Map<String, dynamic> j) => ChatFolder(
        id: j['id'] as String,
        name: j['name'] as String,
        conversationIds: List<String>.from(j['conversationIds'] ?? []),
      );
}

class ChatFolderService {
  ChatFolderService._();
  static const _key = 'chat_folders_v1';
  static final _controller = StreamController<List<ChatFolder>>.broadcast();
  static List<ChatFolder>? _cache;

  static Future<List<ChatFolder>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      _cache = [];
      return _cache!;
    }
    final list = (jsonDecode(raw) as List).map((e) => ChatFolder.fromJson(e as Map<String, dynamic>)).toList();
    _cache = list;
    return list;
  }

  static Future<void> _save(List<ChatFolder> folders) async {
    _cache = folders;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(folders.map((f) => f.toJson()).toList()));
    if (!_controller.isClosed) _controller.add(folders);
  }

  static Stream<List<ChatFolder>> watchFolders() {
    _load().then((f) {
      if (!_controller.isClosed) _controller.add(f);
    });
    return _controller.stream;
  }

  static Future<List<ChatFolder>> getFolders() => _load();

  static Future<void> createFolder(String name) async {
    final folders = await _load();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await _save([...folders, ChatFolder(id: id, name: name, conversationIds: const [])]);
  }

  static Future<void> renameFolder(String id, String newName) async {
    final folders = await _load();
    await _save(folders.map((f) => f.id == id ? f.copyWith(name: newName) : f).toList());
  }

  static Future<void> deleteFolder(String id) async {
    final folders = await _load();
    await _save(folders.where((f) => f.id != id).toList());
  }

  static Future<void> setConversationInFolder(String folderId, String conversationId, bool included) async {
    final folders = await _load();
    await _save(folders.map((f) {
      if (f.id != folderId) return f;
      final ids = List<String>.from(f.conversationIds);
      if (included && !ids.contains(conversationId)) ids.add(conversationId);
      if (!included) ids.remove(conversationId);
      return f.copyWith(conversationIds: ids);
    }).toList());
  }
}
