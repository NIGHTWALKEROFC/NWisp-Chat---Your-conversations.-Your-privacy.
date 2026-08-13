import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ConversationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String conversationIdFor(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return sorted.join('_');
  }

  Future<String> getOrCreateConversation({
    required String otherUid,
    required String myUsername,
    required String otherUsername,
  }) async {
    final myUid = _auth.currentUser!.uid;
    final id = conversationIdFor(myUid, otherUid);
    final ref = _db.collection('conversations').doc(id);
    final existing = await ref.get();
    if (!existing.exists) {
      await ref.set({
        'participants': [myUid, otherUid]..sort(),
        'participantUsernames': {myUid: myUsername, otherUid: otherUsername},
        'lastMessageText': null,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'mutedBy': <String>[],
        'chatTtlHours': null,
      });
    }
    return id;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> conversationsStream() {
    final myUid = _auth.currentUser!.uid;
    return _db
        .collection('conversations')
        .where('participants', arrayContains: myUid)
        .orderBy('lastMessageAt', descending: true)
        .snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> conversationStream(String conversationId) {
    return _db.collection('conversations').doc(conversationId).snapshots();
  }

  (String uid, String username) otherParticipant(Map<String, dynamic> data) {
    final myUid = _auth.currentUser!.uid;
    final participants = List<String>.from(data['participants'] ?? []);
    final otherUid = participants.firstWhere((p) => p != myUid, orElse: () => '');
    final names = Map<String, dynamic>.from(data['participantUsernames'] ?? {});
    return (otherUid, (names[otherUid] as String?) ?? 'Unknown');
  }

  Future<void> updateLastMessage(String conversationId, String preview) {
    return _db.collection('conversations').doc(conversationId).update({
      'lastMessageText': preview,
      'lastMessageAt': FieldValue.serverTimestamp(),
    });
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

  Future<void> clearChat(String conversationId) async {
    final messages = await _db.collection('conversations').doc(conversationId).collection('messages').get();
    for (var i = 0; i < messages.docs.length; i += 450) {
      final chunk = messages.docs.skip(i).take(450);
      final batch = _db.batch();
      for (final doc in chunk) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
    await _db.collection('conversations').doc(conversationId).update({
      'lastMessageText': null,
    });
  }
}
