import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../models/group.dart';
import 'local_message_store.dart';

/// Group metadata (name/avatar/membership) lives in Firestore, the same
/// way 1:1 `conversations/{id}` docs do — see ConversationService. Group
/// MESSAGE content never comes near this class or Firestore at all; that's
/// GroupMessageRelayService's job, fanning encrypted copies through
/// Supabase `message_relay` exactly like 1:1 messages.
class GroupService {
  GroupService._();
  static final instance = GroupService._();

  final _db = FirebaseFirestore.instance;
  String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _cacheSub;

  DocumentReference<Map<String, dynamic>> _ref(String groupId) => _db.collection('groups').doc(groupId);

  /// The `group_` prefix keeps a group id unambiguous from a 1:1
  /// conversation id everywhere the two can end up in the same place —
  /// message_relay.conversation_id, LocalMessageStore rows, the chat list.
  /// A 1:1 id is always two sorted uids joined with `_` and can never
  /// itself start with the literal string "group_", so this is a safe,
  /// collision-free way to tell them apart with zero extra state.
  String newGroupId() => 'group_${const Uuid().v4()}';

  Future<void> createGroup({
    required String groupId,
    required String name,
    String? avatarUrl,
    required List<String> memberUids,
  }) async {
    final myUid = _myUid;
    final members = {myUid, ...memberUids}.toList();
    final cleanName = name.trim().isEmpty ? 'Group' : name.trim();
    await _ref(groupId).set({
      'name': cleanName,
      'avatarUrl': avatarUrl,
      'ownerId': myUid,
      'admins': [myUid],
      'members': members,
      'createdAt': FieldValue.serverTimestamp(),
      'chatTtlHours': null,
      'mutedBy': <String>[],
      'archivedBy': <String>[],
      'description': '',
    });
    await LocalMessageStore.upsertGroupMeta(id: groupId, name: cleanName, avatarUrl: avatarUrl, memberUids: members);
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> groupStream(String groupId) => _ref(groupId).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> myGroupsStream() =>
      _db.collection('groups').where('members', arrayContains: _myUid).snapshots();

  Future<void> renameGroup(String groupId, String name) => _ref(groupId).update({'name': name.trim()});

  Future<void> updateAvatar(String groupId, String? avatarUrl) => _ref(groupId).update({'avatarUrl': avatarUrl});

  Future<void> setChatTtlHours(String groupId, int? hours) => _ref(groupId).update({'chatTtlHours': hours});

  /// Mute/archive, same per-person model as ConversationService's 1:1
  /// versions — a "mutedBy"/"archivedBy" array on the group doc rather
  /// than one shared flag, so muting or archiving a group on your device
  /// has no effect on any other member. Any member can mute/archive
  /// (not just admins) — see firestore.rules' isSelfMutingOrArchiving()
  /// for the matching server-side permission, since the normal group
  /// update rule is otherwise admin-only.
  bool isMutedByMe(Map<String, dynamic> data) {
    final muted = List<String>.from(data['mutedBy'] ?? []);
    return muted.contains(_myUid);
  }

  Future<void> setMuted(String groupId, bool muted) {
    return _ref(groupId).update({
      'mutedBy': muted ? FieldValue.arrayUnion([_myUid]) : FieldValue.arrayRemove([_myUid]),
    });
  }

  bool isArchivedByMe(Map<String, dynamic> data) {
    final archived = List<String>.from(data['archivedBy'] ?? []);
    return archived.contains(_myUid);
  }

  Future<void> setArchived(String groupId, bool archived) {
    return _ref(groupId).update({
      'archivedBy': archived ? FieldValue.arrayUnion([_myUid]) : FieldValue.arrayRemove([_myUid]),
    });
  }

  /// Admin-only, like renameGroup/updateAvatar — a group's description is
  /// shared context for the whole group, not personal preference like
  /// mute/archive above.
  Future<void> updateDescription(String groupId, String description) =>
      _ref(groupId).update({'description': description.trim()});

  Future<void> addMembers(String groupId, List<String> uids) =>
      _ref(groupId).update({'members': FieldValue.arrayUnion(uids)});

  /// Also strips the removed member from `admins` if they were one — a
  /// removed member has no business staying an admin of a group they're
  /// no longer in.
  Future<void> removeMember(String groupId, String uid) {
    return _db.runTransaction((tx) async {
      final ref = _ref(groupId);
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) return;
      final members = List<String>.from(data['members'] ?? [])..remove(uid);
      final admins = List<String>.from(data['admins'] ?? [])..remove(uid);
      tx.update(ref, {'members': members, 'admins': admins});
    });
  }

  Future<void> promoteAdmin(String groupId, String uid) =>
      _ref(groupId).update({'admins': FieldValue.arrayUnion([uid])});

  Future<void> demoteAdmin(String groupId, String uid) =>
      _ref(groupId).update({'admins': FieldValue.arrayRemove([uid])});

  /// Removes me from the group. If I was the owner and other members are
  /// still left, ownership passes to whichever remaining admin (or, if
  /// none, whichever remaining member) comes first — the group doc's
  /// owner-only `allow delete` rule needs SOME owner to still make sense.
  /// If I was the last member, the group doc itself is deleted instead of
  /// leaving an empty, ownerless group behind.
  Future<void> leaveGroup(String groupId) async {
    final myUid = _myUid;
    await _db.runTransaction((tx) async {
      final ref = _ref(groupId);
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) return;
      final members = List<String>.from(data['members'] ?? [])..remove(myUid);
      final admins = List<String>.from(data['admins'] ?? [])..remove(myUid);
      final ownerId = data['ownerId'] as String?;

      if (members.isEmpty) {
        tx.delete(ref);
        return;
      }
      var newOwnerId = ownerId;
      if (ownerId == myUid) {
        newOwnerId = admins.isNotEmpty ? admins.first : members.first;
        if (!admins.contains(newOwnerId)) admins.add(newOwnerId!);
      }
      tx.update(ref, {'members': members, 'admins': admins, 'ownerId': newOwnerId});
    });
    await LocalMessageStore.removeGroupMeta(groupId);
  }

  // ---- lightweight typing indicator, same shape as ConversationService --

  Future<void> setTyping(String groupId, bool isTyping) async {
    await _db
        .collection('groups')
        .doc(groupId)
        .collection('typing')
        .doc(_myUid)
        .set({'isTyping': isTyping, 'updatedAt': FieldValue.serverTimestamp()});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> typingStream(String groupId) =>
      _db.collection('groups').doc(groupId).collection('typing').snapshots();

  /// Call once per sign-in, right next to MessageRelayService.start() (see
  /// main.dart). Keeps LocalMessageStore's `group_meta` cache in sync with
  /// Firestore so the chat list can show a group's current name/avatar
  /// even from the local cache alone (e.g. briefly offline on cold start).
  void startCaching() {
    _cacheSub?.cancel();
    _cacheSub = myGroupsStream().listen((snap) {
      for (final doc in snap.docs) {
        final g = Group.fromDoc(doc);
        LocalMessageStore.upsertGroupMeta(id: g.id, name: g.name, avatarUrl: g.avatarUrl, memberUids: g.members);
      }
    });
  }

  void stopCaching() {
    _cacheSub?.cancel();
    _cacheSub = null;
  }
}
