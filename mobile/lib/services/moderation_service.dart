import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ModerationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _myUid => _auth.currentUser!.uid;

  Future<void> blockUser(String uid) {
    return _db.collection('users').doc(_myUid).update({
      'blockedUsers': FieldValue.arrayUnion([uid]),
    });
  }

  Future<void> unblockUser(String uid) {
    return _db.collection('users').doc(_myUid).update({
      'blockedUsers': FieldValue.arrayRemove([uid]),
    });
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> myProfileStream() {
    return _db.collection('users').doc(_myUid).snapshots();
  }

  Future<bool> isBlocked(String uid) async {
    final doc = await _db.collection('users').doc(_myUid).get();
    final blocked = List<String>.from(doc.data()?['blockedUsers'] ?? []);
    return blocked.contains(uid);
  }

  Future<void> reportUser(String uid, String reason) {
    return _db.collection('reports').add({
      'reporterUid': _myUid,
      'reportedUid': uid,
      'reason': reason,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
