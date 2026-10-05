import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: private nicknames for contacts.
///
/// A nickname exists ONLY on this phone — the other person is never told and
/// never sees it. Where a nickname is set, NWisp shows it instead of their
/// username in your chat list, the chat title, your contacts and group
/// messages. The real username is still visible on their profile / chat
/// settings, so you can always tell who it is.
class NicknameService {
  NicknameService._();
  static final instance = NicknameService._();

  /// Ticks when any nickname changes so lists redraw.
  final ValueNotifier<int> changes = ValueNotifier(0);

  String? _loadedFor;
  Map<String, String> _names = {};

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> load() async {
    final uid = _uid;
    if (uid == null || _loadedFor == uid) return;
    _loadedFor = uid;
    _names = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('nicknames_v1_$uid');
      if (raw != null) {
        _names = Map<String, String>.from(jsonDecode(raw) as Map);
      }
    } catch (e) {
      debugPrint('NicknameService: could not read nicknames: $e');
    }
    changes.value++;
  }

  /// The nickname for [uid], or null if none is set.
  String? nicknameFor(String uid) {
    final n = _names[uid]?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// What to show for this person: the nickname if there is one, otherwise
  /// the real name that was passed in.
  String display(String uid, String realName) => nicknameFor(uid) ?? realName;

  Future<void> setNickname(String uid, String? nickname) async {
    await load();
    final me = _uid;
    if (me == null) return;
    final trimmed = nickname?.trim() ?? '';
    if (trimmed.isEmpty) {
      _names.remove(uid);
    } else {
      _names[uid] = trimmed;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nicknames_v1_$me', jsonEncode(_names));
    } catch (_) {}
    changes.value++;
  }

  /// For the encrypted backup.
  Map<String, String> exportAll() => Map.of(_names);

  Future<void> importAll(Map<String, String> names) async {
    await load();
    final me = _uid;
    if (me == null) return;
    names.forEach((uid, n) => _names.putIfAbsent(uid, () => n));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nicknames_v1_$me', jsonEncode(_names));
    } catch (_) {}
    changes.value++;
  }

  void resetMemory() {
    _loadedFor = null;
    _names = {};
  }
}

/// Small dialog used from several screens. Returns true if something changed.
/// (Defined here so each screen needs only one import and one call.)
class NicknameResult {
  final bool changed;
  const NicknameResult(this.changed);
}
