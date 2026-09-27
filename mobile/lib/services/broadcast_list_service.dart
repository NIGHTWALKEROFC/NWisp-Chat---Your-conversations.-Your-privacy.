import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'conversation_service.dart';
import 'message_relay_service.dart';

/// Feature: broadcast lists. A LIGHTER, DIFFERENT thing from a group (see
/// group_service.dart) or a Community (community_service.dart): a broadcast
/// list is a named set of contacts, kept ONLY on this device — there is no
/// shared Firestore document the way a group/community has one, and the
/// people on the list are never told they're on it.
///
/// Sending to a broadcast list fans out through the exact same 1:1 send
/// path every other message in this app already uses
/// (MessageRelayService.sendMessage, one call per member) — each person
/// just receives a normal message from you, in their normal chat with you,
/// same as if you'd typed it to them individually. Replies come back as
/// ordinary 1:1 replies in that same chat, not into anything shared.
///
/// Modeled directly on ChatFolderService's own pattern (SharedPreferences +
/// broadcast stream) — a broadcast list is exactly as sensitive as a folder
/// name, i.e. not very, and genuinely personal-to-this-device the same way.
class BroadcastList {
  final String id;
  final String name;
  final List<String> memberUids;

  const BroadcastList({required this.id, required this.name, required this.memberUids});

  BroadcastList copyWith({String? name, List<String>? memberUids}) =>
      BroadcastList(id: id, name: name ?? this.name, memberUids: memberUids ?? this.memberUids);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'memberUids': memberUids};

  factory BroadcastList.fromJson(Map<String, dynamic> j) => BroadcastList(
        id: j['id'] as String,
        name: j['name'] as String,
        memberUids: List<String>.from(j['memberUids'] ?? []),
      );
}

/// One member's outcome from [BroadcastListService.sendToList] — shown to
/// the sender afterward so a failed delivery to one person doesn't quietly
/// disappear; it never reaches the OTHER members, since there's no shared
/// thread for it to appear in.
class BroadcastSendOutcome {
  final String memberUid;
  final bool success;
  final String? error;
  const BroadcastSendOutcome({required this.memberUid, required this.success, this.error});
}

/// One past broadcast, kept locally purely so the sender can see what they
/// already sent to a given list and how it went — this is NOT a shared
/// thread; nothing here is fetched back from anyone's device.
class BroadcastHistoryEntry {
  final String text;
  final DateTime sentAt;
  final int successCount;
  final int failCount;

  const BroadcastHistoryEntry({
    required this.text,
    required this.sentAt,
    required this.successCount,
    required this.failCount,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'sentAt': sentAt.millisecondsSinceEpoch,
        'successCount': successCount,
        'failCount': failCount,
      };

  factory BroadcastHistoryEntry.fromJson(Map<String, dynamic> j) => BroadcastHistoryEntry(
        text: j['text'] as String,
        sentAt: DateTime.fromMillisecondsSinceEpoch(j['sentAt'] as int),
        successCount: j['successCount'] as int? ?? 0,
        failCount: j['failCount'] as int? ?? 0,
      );
}

class BroadcastListService {
  BroadcastListService._();

  static const _listsKey = 'broadcast_lists_v1';
  static const _historyKeyPrefix = 'broadcast_history_v1_';
  static const _maxHistoryPerList = 50;

  static final _controller = StreamController<List<BroadcastList>>.broadcast();
  static List<BroadcastList>? _cache;

  static final _conversationService = ConversationService();

  // ---- lists themselves --------------------------------------------------

  static Future<List<BroadcastList>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listsKey);
    if (raw == null) {
      _cache = [];
      return _cache!;
    }
    final list = (jsonDecode(raw) as List).map((e) => BroadcastList.fromJson(e as Map<String, dynamic>)).toList();
    _cache = list;
    return list;
  }

  static Future<void> _save(List<BroadcastList> lists) async {
    _cache = lists;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listsKey, jsonEncode(lists.map((l) => l.toJson()).toList()));
    if (!_controller.isClosed) _controller.add(lists);
  }

  static Stream<List<BroadcastList>> watchLists() {
    _load().then((l) {
      if (!_controller.isClosed) _controller.add(l);
    });
    return _controller.stream;
  }

  static Future<List<BroadcastList>> getLists() => _load();

  static Future<BroadcastList> createList(String name, List<String> memberUids) async {
    final lists = await _load();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final list = BroadcastList(id: id, name: name, memberUids: memberUids);
    await _save([...lists, list]);
    return list;
  }

  static Future<void> renameList(String id, String newName) async {
    final lists = await _load();
    await _save(lists.map((l) => l.id == id ? l.copyWith(name: newName) : l).toList());
  }

  static Future<void> setMembers(String id, List<String> memberUids) async {
    final lists = await _load();
    await _save(lists.map((l) => l.id == id ? l.copyWith(memberUids: memberUids) : l).toList());
  }

  static Future<void> deleteList(String id) async {
    final lists = await _load();
    await _save(lists.where((l) => l.id != id).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_historyKeyPrefix$id');
  }

  // ---- sending -------------------------------------------------------------

  /// Sends [text] to every member of [list], one ordinary 1:1 message per
  /// person (see this class's own doc comment above for why it's built
  /// this way instead of a shared thread). A member who fails (blocked you,
  /// missing keys, offline relay error, etc.) doesn't stop the rest from
  /// going out — every member is attempted independently, and the full set
  /// of per-member outcomes comes back so the sender can see exactly who
  /// did and didn't get it.
  static Future<List<BroadcastSendOutcome>> sendToList(BroadcastList list, String text) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) {
      return [for (final uid in list.memberUids) BroadcastSendOutcome(memberUid: uid, success: false, error: 'Not signed in')];
    }
    // Feature: disappearing messages — a broadcast honors the sender's own
    // default TTL, same as any ordinary chat where nothing more specific
    // has been chosen for that particular conversation.
    int ttlHours = 0;
    try {
      final doc = await AuthService().currentUserPrivateProfile();
      ttlHours = (doc.data()?['messageTtlHours'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    final outcomes = <BroadcastSendOutcome>[];
    for (final memberUid in list.memberUids) {
      try {
        final conversationId = _conversationService.conversationIdFor(myUid, memberUid);
        await _conversationService.ensureConversation(otherUid: memberUid);
        await MessageRelayService.sendMessage(
          conversationId: conversationId,
          recipientUid: memberUid,
          text: text,
          ttlHours: ttlHours,
        );
        outcomes.add(BroadcastSendOutcome(memberUid: memberUid, success: true));
      } catch (e) {
        outcomes.add(BroadcastSendOutcome(memberUid: memberUid, success: false, error: e.toString()));
      }
    }

    final successCount = outcomes.where((o) => o.success).length;
    await _appendHistory(
      list.id,
      BroadcastHistoryEntry(
        text: text,
        sentAt: DateTime.now(),
        successCount: successCount,
        failCount: outcomes.length - successCount,
      ),
    );
    return outcomes;
  }

  // ---- per-list send history (local only, sender's own reference) --------

  static Future<List<BroadcastHistoryEntry>> getHistory(String listId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_historyKeyPrefix$listId');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) => BroadcastHistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> _appendHistory(String listId, BroadcastHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getHistory(listId);
    final updated = [entry, ...existing].take(_maxHistoryPerList).toList();
    await prefs.setString('$_historyKeyPrefix$listId', jsonEncode(updated.map((e) => e.toJson()).toList()));
  }
}
