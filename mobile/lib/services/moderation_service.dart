import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// blockedUsers now lives at users/{uid}/private/profile (owner-only —
/// see firestore.rules) instead of directly on users/{uid}, which used to
/// let any signed-in user read who you'd blocked.
///
/// Blocking/unblocking now writes to TWO places: your own private profile
/// (for your own "Blocked users" screen + isBlocked() checks) and a small
/// `blocks/{blockerUid}_{blockedUid}` doc, which is the only thing that
/// tells the OTHER person's device "you've been blocked, don't let them
/// send" (see MessageRelayService._checkNotBlocked) — without exposing your
/// whole block list to them or anyone else.
class ModerationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _myUid => _auth.currentUser!.uid;

  DocumentReference<Map<String, dynamic>> get _profileRef =>
      _db.collection('users').doc(_myUid).collection('private').doc('profile');

  DocumentReference<Map<String, dynamic>> _blockDocRef(String blockedUid) =>
      _db.collection('blocks').doc('${_myUid}_$blockedUid');

  Future<void> blockUser(String uid) async {
    final batch = _db.batch();
    batch.set(_profileRef, {
      'blockedUsers': FieldValue.arrayUnion([uid]),
    }, SetOptions(merge: true));
    batch.set(_blockDocRef(uid), {
      'blockerUid': _myUid,
      'blockedUid': uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<void> unblockUser(String uid) async {
    final batch = _db.batch();
    batch.set(_profileRef, {
      'blockedUsers': FieldValue.arrayRemove([uid]),
    }, SetOptions(merge: true));
    batch.delete(_blockDocRef(uid));
    await batch.commit();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> myProfileStream() {
    return _profileRef.snapshots();
  }

  Future<bool> isBlocked(String uid) async {
    final doc = await _profileRef.get();
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
