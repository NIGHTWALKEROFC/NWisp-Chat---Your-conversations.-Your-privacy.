
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../models/group.dart';
import 'group_message_relay_service.dart';
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
    // Feature: announcement-only group — only admins can post from day one.
    // Same field the "Only admins can send messages" toggle in Group info
    // flips later (see setOnlyAdminsCanSend).
    bool onlyAdminsCanSend = false,
    // Feature: Community — see CommunityService. A community is a normal
    // group document plus these flags (its PUBLIC listing is a separate
    // `communities/{groupId}` document).
    bool isCommunity = false,
    int? maxMembers,
    String description = '',
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
      'pinnedBy': <String>[],
      'description': description.trim(),
      'onlyAdminsCanSend': onlyAdminsCanSend,
      if (isCommunity) 'isCommunity': true,
      if (isCommunity && maxMembers != null) 'maxMembers': maxMembers,
      if (isCommunity) 'bannedUids': <String>[],
    });
    await LocalMessageStore.upsertGroupMeta(id: groupId, name: cleanName, avatarUrl: avatarUrl, memberUids: members);
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> groupStream(String groupId) => _ref(groupId).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> myGroupsStream() =>
      _db.collection('groups').where('members', arrayContains: _myUid).snapshots();

  /// Feature: Community. If this group is a community, mirror a changed
  /// name / photo / description into its PUBLIC listing too. Fire-and-forget
  /// on purpose (never awaited, errors swallowed): for a normal group there
  /// is no listing, so the write is simply rejected and nothing happens —
  /// and an offline write must never hold up the rename itself.
  void _mirrorToListing(String groupId, Map<String, dynamic> fields) {
    _db.collection('communities').doc(groupId).update(fields).catchError((_) {});
  }

  Future<void> renameGroup(String groupId, String name) async {
    await _ref(groupId).update({'name': name.trim()});
    _mirrorToListing(groupId, {'name': name.trim(), 'nameLower': name.trim().toLowerCase()});
  }

  Future<void> updateAvatar(String groupId, String? avatarUrl) async {
    await _ref(groupId).update({'avatarUrl': avatarUrl});
    _mirrorToListing(groupId, {'avatarUrl': avatarUrl});
  }

  Future<void> setChatTtlHours(String groupId, int? hours) => _ref(groupId).update({'chatTtlHours': hours});

  /// Feature: group security setting — see Group.onlyAdminsCanSend. Admin
  /// only, enforced by firestore.rules' existing isGroupAdmin() check on
  /// this same groups/{groupId} document (no rules change needed — that
  /// check already covers ANY field on this doc, this is just one more).
  Future<void> setOnlyAdminsCanSend(String groupId, bool value) async {
    await _ref(groupId).update({'onlyAdminsCanSend': value});
    _mirrorToListing(groupId, {'onlyAdminsCanSend': value});
  }

  /// Group security settings added 2026-09-10 — same admin-only pattern
  /// and same "no rules change needed" reasoning as setOnlyAdminsCanSend
  /// above (isGroupAdmin() already covers every field on this document).
  Future<void> setMediaAutoDownload(String groupId, bool value) =>
      _ref(groupId).update({'mediaAutoDownload': value});

  Future<void> setReadReceiptsEnabled(String groupId, bool value) =>
      _ref(groupId).update({'readReceiptsEnabled': value});

  Future<void> setHideMemberListFromNonAdmins(String groupId, bool value) =>
      _ref(groupId).update({'hideMemberListFromNonAdmins': value});

  /// Feature: "clear on exit" ephemeral view mode, group version.
  /// Admin-only — enforced the same way as setOnlyAdminsCanSend above
  /// (existing firestore.rules already gate writes to this whole
  /// document to admins, so no rules change needed here either).
  Future<void> setEphemeralViewEnabled(String groupId, bool value) =>
      _ref(groupId).update({'ephemeralViewEnabled': value});

  /// One-shot (not a stream) lookups for MessageRelayService, which needs
  /// to check a group's setting once per incoming message/receipt rather
  /// than keep a live subscription open per group. Defaults match
  /// Group.fromDoc's defaults (true/true) so a group with neither field
  /// set yet — i.e. every group that existed before this feature —
  /// behaves exactly as it always has.
  Future<bool> isMediaAutoDownloadEnabled(String groupId) async {
    final doc = await _ref(groupId).get();
    return (doc.data()?['mediaAutoDownload'] as bool?) ?? true;
  }

  Future<bool> isReadReceiptsEnabled(String groupId) async {
    final doc = await _ref(groupId).get();
    return (doc.data()?['readReceiptsEnabled'] as bool?) ?? true;
  }

  /// Feature: announcement-only groups. Is [uid] (default: me) allowed to
  /// POST a message into [groupId] right now? True for everyone in a normal
  /// group; in an announcement-only group (`onlyAdminsCanSend`) true only
  /// for admins.
  ///
  /// Used on BOTH ends: the sender's own send path refuses early, and — the
  /// part that actually matters, because the relay is zero-knowledge and can't
  /// judge anything itself — every RECEIVING phone checks it before it
  /// stores a message from someone else (see MessageRelayService._handleRow).
  /// A group that no longer exists reads as "allowed" (nothing to enforce).
  ///
  /// Throws if the group doc can't be read at all (e.g. offline with nothing
  /// cached) — the receive side WANTS that, so the relay row is kept and
  /// retried instead of being wrongly accepted or wrongly thrown away.
  Future<bool> mayPost(String groupId, {String? uid}) async {
    final data = (await _ref(groupId).get()).data();
    if (data == null) return true;
    final restricted = (data['onlyAdminsCanSend'] as bool?) ?? false;
    if (!restricted) return true;
    final who = uid ?? _myUid;
    return List<String>.from(data['admins'] ?? const []).contains(who);
  }

  /// Mute/archive, same per-person model as ConversationService's 1:1
  /// versions — a "mutedBy"/"archivedBy" array on the group doc rather
  /// than one shared flag, so muting or archiving a group on your device
  /// has no effect on any other member. Any member can mute/archive
  /// (not just admins) — see firestore.rules' isSelfMutingOrArchiving()
  /// for the matching server-side permission, since the normal group
  /// update rule is otherwise admin-only.
  ///
  /// Feature: timed mute. Same two-part model as ConversationService — my uid
  /// in `mutedBy` is a forever-mute, and `mutedUntil.<myUid>` is a timed
  /// mute that quietly stops counting once its time has passed.
  bool isMutedByMe(Map<String, dynamic> data) {
    final muted = List<String>.from(data['mutedBy'] ?? []);
    if (muted.contains(_myUid)) return true;
    final until = muteExpiryFor(data);
    return until != null && until.isAfter(DateTime.now());
  }

  DateTime? muteExpiryFor(Map<String, dynamic> data) {
    final map = data['mutedUntil'];
    if (map is! Map) return null;
    final value = map[_myUid];
    return value is Timestamp ? value.toDate() : null;
  }

  /// Mute forever (`muted: true`) or unmute completely (`muted: false`,
  /// which also cancels any timed mute that was running).
  Future<void> setMuted(String groupId, bool muted) {
    return _ref(groupId).update({
      'mutedBy': muted ? FieldValue.arrayUnion([_myUid]) : FieldValue.arrayRemove([_myUid]),
      'mutedUntil.$_myUid': FieldValue.delete(),
    });
  }

  Future<void> muteFor(String groupId, Duration duration) {
    return _ref(groupId).update({
      'mutedBy': FieldValue.arrayRemove([_myUid]),
      'mutedUntil.$_myUid': Timestamp.fromDate(DateTime.now().add(duration)),
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

  bool isPinnedByMe(Map<String, dynamic> data) {
    final pinned = List<String>.from(data['pinnedBy'] ?? []);
    return pinned.contains(_myUid);
  }

  Future<void> setPinned(String groupId, bool pinned) {
    return _ref(groupId).update({
      'pinnedBy': pinned ? FieldValue.arrayUnion([_myUid]) : FieldValue.arrayRemove([_myUid]),
    });
  }

  /// Admin-only, like renameGroup/updateAvatar — a group's description is
  /// shared context for the whole group, not personal preference like
  /// mute/archive above.
  Future<void> updateDescription(String groupId, String description) async {
    await _ref(groupId).update({'description': description.trim()});
    _mirrorToListing(groupId, {'description': description.trim()});
  }

  Future<void> addMembers(String groupId, List<String> uids) =>
      _ref(groupId).update({'members': FieldValue.arrayUnion(uids)});

  CollectionReference<Map<String, dynamic>> get _groupInviteRequestsRef =>
      _db.collection('groupInviteRequests');

  String _inviteRequestId(String groupId, String toUid) => '${groupId}_$toUid';

  /// Invites [toUid] to a group WITHOUT adding them yet — the flow for
  /// anyone who ISN'T already the inviting admin's contact. Firestore
  /// rules only let an admin directly rewrite a group's `members` array
  /// for people already established as a mutual contact-style
  /// relationship elsewhere in the app (see [addMembers], used by
  /// group_info_screen.dart / create_group_screen.dart, both of which
  /// only ever list the admin's own contacts as candidates); this app
  /// deliberately does NOT extend that direct-add power to strangers, on
  /// the reasoning that being silently pulled into a group — exposing
  /// your presence and messages to people you've never agreed to talk to
  /// — deserves the same explicit consent a 1:1 contact request already
  /// requires (see ContactService.sendRequest). The invited person
  /// accepts or declines from their own device (see
  /// [myGroupInviteRequestsStream] / [acceptGroupInvite] /
  /// [declineGroupInvite]) — only THEY can turn an accepted invite into
  /// actual membership (see firestore.rules'
  /// isSelfJoiningViaAcceptedInvite()), an admin can't do it for them.
  Future<void> inviteToGroup({
    required String groupId,
    required String groupName,
    String? groupAvatarUrl,
    required String toUid,
    required String toUsername,
  }) async {
    final myUid = _myUid;
    final myProfile = await _db.collection('users').doc(myUid).get();
    final myUsername = (myProfile.data()?['username'] as String?) ?? '';
    await _groupInviteRequestsRef.doc(_inviteRequestId(groupId, toUid)).set({
      'groupId': groupId,
      'groupName': groupName,
      'groupAvatarUrl': groupAvatarUrl,
      'fromUid': myUid,
      'fromUsername': myUsername,
      'toUid': toUid,
      'toUsername': toUsername,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myGroupInviteRequestsStream() {
    return _groupInviteRequestsRef
        .where('toUid', isEqualTo: _myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Deliberately two sequential writes, not a batch: firestore.rules'
  /// isSelfJoiningViaAcceptedInvite() checks the invite doc's status AT
  /// THE MOMENT of the members-array write, so that status update has to
  /// actually be committed first, not just queued alongside it.
  Future<void> acceptGroupInvite({required String requestId, required String groupId}) async {
    await _groupInviteRequestsRef.doc(requestId).update({'status': 'accepted'});
    await _ref(groupId).update({'members': FieldValue.arrayUnion([_myUid])});
  }

  Future<void> declineGroupInvite(String requestId) =>
      _groupInviteRequestsRef.doc(requestId).update({'status': 'declined'});

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

  /// Feature: Community moderation — remove someone AND stop them from
  /// joining this community again by themselves. Admin-only (firestore.rules
  /// already limits every write to a group document to its admins).
  Future<void> banMember(String groupId, String uid) {
    return _db.runTransaction((tx) async {
      final ref = _ref(groupId);
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) return;
      final members = List<String>.from(data['members'] ?? [])..remove(uid);
      final admins = List<String>.from(data['admins'] ?? [])..remove(uid);
      final banned = List<String>.from(data['bannedUids'] ?? []);
      if (!banned.contains(uid)) banned.add(uid);
      tx.update(ref, {'members': members, 'admins': admins, 'bannedUids': banned});
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

  /// Feature: ownership transfer. Deliberately choosing a new owner
  /// WHILE the current owner is still in the group — separate from the
  /// automatic reassignment in [leaveGroup] above (which only ever
  /// triggers when the owner is leaving/losing access, and picks
  /// whoever happens to be the first admin rather than someone the
  /// owner actually chose). Owner-only (enforced by firestore.rules'
  /// new isOwnerTransferringOwnership() — needs republishing). The new
  /// owner is added to admins as part of the same write if they aren't
  /// one already, since an owner who isn't also an admin wouldn't make
  /// sense.
  Future<void> transferOwnership(String groupId, String newOwnerUid) async {
    final ref = _ref(groupId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) return;
      final admins = List<String>.from(data['admins'] ?? []);
      if (!admins.contains(newOwnerUid)) admins.add(newOwnerUid);
      tx.update(ref, {'ownerId': newOwnerUid, 'admins': admins});
    });
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

  /// Call once per sign-in, alongside [startCaching] (see main.dart).
  /// Sweeps EVERY group the person is currently in for queued resends
  /// (see ContactNotUpgradedException / GroupMessageRelayService.
  /// retryPendingResends) — not just whichever group they happen to open
  /// first — so a message queued for a member who hadn't updated yet
  /// actually reaches them once they do, even for a group the sender
  /// doesn't reopen right away.
  Future<void> retryAllPendingResends() async {
    final groupIds = await LocalMessageStore.groupIdsWithPendingResends();
    for (final groupId in groupIds) {
      try {
        await GroupMessageRelayService.retryPendingResends(groupId);
      } catch (_) {
        // best-effort sweep — one group's failure shouldn't block the rest
      }
    }
  }

  void stopCaching() {
    _cacheSub?.cancel();
    _cacheSub = null;
  }
}
