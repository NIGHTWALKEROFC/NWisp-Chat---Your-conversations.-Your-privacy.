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
        'chatTtlHours': null,
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

  Future<void> setChatTtlHours(String conversationId, int? hours) {
    return _db.collection('conversations').doc(conversationId).update({'chatTtlHours': hours});
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
