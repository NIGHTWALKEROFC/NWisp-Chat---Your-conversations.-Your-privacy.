import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Manages 1:1 conversations. Conversation IDs are deterministic
/// (sorted uids joined with '_'), so two users always land on the same
/// conversation document without needing a lookup query first.
class ConversationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String conversationIdFor(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return sorted.join('_');
  }

  /// Creates the conversation document if it doesn't exist yet, and
  /// returns its ID either way.
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
      });
    }
    return id;
  }

  /// Conversations the current user is part of, most recent first.
  Stream<QuerySnapshot<Map<String, dynamic>>> conversationsStream() {
    final myUid = _auth.currentUser!.uid;
    return _db
        .collection('conversations')
        .where('participants', arrayContains: myUid)
        .orderBy('lastMessageAt', descending: true)
        .snapshots();
  }

  /// Given a conversation doc's data, returns the other participant's
  /// uid and display name.
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
}
