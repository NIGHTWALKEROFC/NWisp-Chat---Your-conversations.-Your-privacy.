import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ConversationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String conversationIdFor(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return sorted.join('_');
  }

  Future<void> ensureConversation({
    required String otherUid,
  }) async {
    final myUid = _auth.currentUser!.uid;
    final id = conversationIdFor(myUid, otherUid);
    final ref = _db.collection('conversations').doc(id);
    final existing = await ref.get();
    if (!existing.exists) {
      await ref.set({
        'participants': [myUid, otherUid]..sort(),
        'createdAt': FieldValue.serverTimestamp(),
        'mutedBy': <String>[],
        'archivedBy': <String>[],
        'pinnedBy': <String>[],
        'chatTtlHours': null,
        'ephemeralViewEnabled': false,
        // Feature: permission-gated forwarding — restricted by default. See
        // the forwarding section at the bottom of this class, and the
        // matching transition rules in firestore.rules.
        'forwardingEnabled': false,
        'forwardingRequestedBy': null,
      });
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> conversationStream(String conversationId) {
    return _db.collection('conversations').doc(conversationId).snapshots();
  }

  /// Muted means EITHER the old forever-mute (my uid is in `mutedBy`) OR a
  /// timed mute that hasn't run out yet (`mutedUntil.<myUid>` is in the
  /// future). A timed mute simply stops counting once its time passes — no
  /// clean-up job is needed, and the same check is done server-side by the
  /// send-push Edge Function so push notifications stop/resume on time too.
  bool isMutedByMe(Map<String, dynamic> data) {
    final myUid = _auth.currentUser!.uid;
    final muted = List<String>.from(data['mutedBy'] ?? []);
    if (muted.contains(myUid)) return true;
    final until = muteExpiryFor(data);
    return until != null && until.isAfter(DateTime.now());
  }

  /// When my current TIMED mute ends, or null if I have none (a forever-mute
  /// also returns null — see [isMutedByMe] for the combined answer).
  DateTime? muteExpiryFor(Map<String, dynamic> data) {
    final map = data['mutedUntil'];
    if (map is! Map) return null;
    final value = map[_auth.currentUser!.uid];
    return value is Timestamp ? value.toDate() : null;
  }

  /// Mute forever (`muted: true`) or unmute completely (`muted: false`,
  /// which also cancels any timed mute that was running).
  Future<void> setMuted(String conversationId, bool muted) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({
      'mutedBy': muted ? FieldValue.arrayUnion([myUid]) : FieldValue.arrayRemove([myUid]),
      'mutedUntil.$myUid': FieldValue.delete(),
    });
  }

  /// Feature: timed mute (24 hours, 1 week, custom…). Replaces any earlier
  /// mute of either kind for this chat.
  Future<void> muteFor(String conversationId, Duration duration) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({
      'mutedBy': FieldValue.arrayRemove([myUid]),
      'mutedUntil.$myUid': Timestamp.fromDate(DateTime.now().add(duration)),
    });
  }

  /// Archiving hides a chat from the main chat list without leaving it or
  /// deleting anything — same per-person model as [isMutedByMe]/
  /// [setMuted] above (an "archivedBy" array, not a single shared flag),
  /// so archiving a chat on your device doesn't affect what the other
  /// person sees on theirs. Sending or receiving a new message in an
  /// archived chat does NOT auto-unarchive it (matches WhatsApp) — the
  /// person archived it on purpose and gets to decide when it's worth
  /// surfacing again.
  bool isArchivedByMe(Map<String, dynamic> data) {
    final archived = List<String>.from(data['archivedBy'] ?? []);
    return archived.contains(_auth.currentUser!.uid);
  }

  Future<void> setArchived(String conversationId, bool archived) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({
      'archivedBy': archived ? FieldValue.arrayUnion([myUid]) : FieldValue.arrayRemove([myUid]),
    });
  }

  /// Pinning keeps a chat at the top of the list — WhatsApp's long-press
  /// "Pin" — same per-person model as mute/archive above.
  bool isPinnedByMe(Map<String, dynamic> data) {
    final pinned = List<String>.from(data['pinnedBy'] ?? []);
    return pinned.contains(_auth.currentUser!.uid);
  }

  Future<void> setPinned(String conversationId, bool pinned) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({
      'pinnedBy': pinned ? FieldValue.arrayUnion([myUid]) : FieldValue.arrayRemove([myUid]),
    });
  }

  Future<void> setChatTtlHours(String conversationId, int? hours) {
    return _db.collection('conversations').doc(conversationId).update({'chatTtlHours': hours});
  }

  /// Feature: "clear on exit" ephemeral view mode. Shared/visible to both
  /// people (either can turn it on or off — there's no per-person owner
  /// for a 1:1 chat the way group admin gates it), default false. This
  /// flag only controls whether each device wipes ITS OWN local copy of
  /// THIS ONE conversation when its chat screen closes — see
  /// LocalMessageStore.clearConversation, called from
  /// ChatDetailScreen.dispose(). Turning this on never sends anything to
  /// the relay and never deletes anything on the other person's device.
  Future<void> setEphemeralViewEnabled(String conversationId, bool value) {
    return _db.collection('conversations').doc(conversationId).update({'ephemeralViewEnabled': value});
  }

  bool isEphemeralViewEnabled(Map<String, dynamic> data) => data['ephemeralViewEnabled'] == true;

  // ---- Feature: permission-gated message forwarding ----------------------
  //
  // Two fields on the conversation doc, shared by both people:
  //   forwardingEnabled       bool   — false by default (restricted)
  //   forwardingRequestedBy   uid?   — who asked, while a request is pending
  //
  // The rules of the game (enforced again server-side in firestore.rules, so
  // a modified app can't skip them):
  //   * Turning forwarding ON always needs the OTHER person's approval:
  //     one person requests, the other approves.
  //   * Once on, it applies to BOTH people in this chat.
  //   * Either person can turn it OFF at any moment, alone, with no
  //     permission — privacy wins over convenience.
  //   * Turning it on again later means a fresh request.

  bool isForwardingEnabled(Map<String, dynamic> data) => data['forwardingEnabled'] == true;

  /// uid of whoever has a pending request open, or null if none.
  String? forwardingRequestedBy(Map<String, dynamic> data) {
    final v = data['forwardingRequestedBy'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// I asked, and I'm still waiting for the other person.
  bool hasMyPendingForwardingRequest(Map<String, dynamic> data) =>
      !isForwardingEnabled(data) && forwardingRequestedBy(data) == _auth.currentUser!.uid;

  /// The OTHER person asked, and it's waiting on ME to allow or deny.
  bool hasIncomingForwardingRequest(Map<String, dynamic> data) {
    final by = forwardingRequestedBy(data);
    return !isForwardingEnabled(data) && by != null && by != _auth.currentUser!.uid;
  }

  Future<void> requestForwarding(String conversationId) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({'forwardingRequestedBy': myUid});
  }

  /// Withdraw my own pending request, or decline one from the other person —
  /// either way the request field just goes back to empty.
  Future<void> clearForwardingRequest(String conversationId) {
    return _db.collection('conversations').doc(conversationId).update({'forwardingRequestedBy': null});
  }

  /// Approve the OTHER person's pending request. Only valid while their
  /// request is open — firestore.rules refuses this write otherwise, so
  /// nobody can switch forwarding on for themselves.
  Future<void> approveForwardingRequest(String conversationId) {
    return _db.collection('conversations').doc(conversationId).update({
      'forwardingEnabled': true,
      'forwardingRequestedBy': null,
    });
  }

  /// Turn forwarding off. No permission needed, ever.
  Future<void> disableForwarding(String conversationId) {
    return _db.collection('conversations').doc(conversationId).update({
      'forwardingEnabled': false,
      'forwardingRequestedBy': null,
    });
  }

  /// Short-lived typing flag — this is presence-style metadata, not message
  /// content, so it's fine to keep in Firestore.
  Future<void> setTyping(String conversationId, bool isTyping) async {
    final uid = _auth.currentUser!.uid;
    await _db
        .collection('conversations').doc(conversationId)
        .collection('typing').doc(uid)
        .set({'isTyping': isTyping, 'updatedAt': FieldValue.serverTimestamp()});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> typingStream(String conversationId) {
    return _db
        .collection('conversations').doc(conversationId)
        .collection('typing')
        .snapshots();
  }
}
