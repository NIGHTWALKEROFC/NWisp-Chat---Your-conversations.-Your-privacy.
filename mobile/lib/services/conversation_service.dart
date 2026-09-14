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
      });
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> conversationStream(String conversationId) {
    return _db.collection('conversations').doc(conversationId).snapshots();
  }

  bool isMutedByMe(Map<String, dynamic> data) {
    final muted = List<String>.from(data['mutedBy'] ?? []);
    return muted.contains(_auth.currentUser!.uid);
  }

  Future<void> setMuted(String conversationId, bool muted) {
    final myUid = _auth.currentUser!.uid;
    return _db.collection('conversations').doc(conversationId).update({
      'mutedBy': muted ? FieldValue.arrayUnion([myUid]) : FieldValue.arrayRemove([myUid]),
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
