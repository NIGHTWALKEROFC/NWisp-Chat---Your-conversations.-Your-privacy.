import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ContactService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _myUid => _auth.currentUser!.uid;

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final lower = query.trim().toLowerCase();
    if (lower.isEmpty) return [];
    final snap = await _db
        .collection('users')
        .orderBy('usernameLower')
        .startAt([lower])
        .endAt(['$lower\uf8ff'])
        .limit(20)
        .get();
    return snap.docs
        .where((d) => d.id != _myUid)
        .map((d) => {'uid': d.id, ...d.data()})
        .toList();
  }

  Future<Set<String>> myContactUids() async {
    final snap = await _db.collection('users').doc(_myUid).collection('contacts').get();
    return snap.docs.map((d) => d.id).toSet();
  }

  Future<Set<String>> myPendingOutgoingUids() async {
    final snap = await _db.collection('contactRequests').where('fromUid', isEqualTo: _myUid).get();
    return snap.docs
        .where((d) => d.data()['status'] == 'pending')
        .map((d) => d.data()['toUid'] as String)
        .toSet();
  }

  Future<void> sendRequest({required String toUid, required String toUsername, required String myUsername}) async {
    if (toUid == _myUid) throw Exception("You can't add yourself");

    final alreadyContact = await _db.collection('users').doc(_myUid).collection('contacts').doc(toUid).get();
    if (alreadyContact.exists) throw Exception('Already in your contacts');

    final existing = await _db
        .collection('contactRequests')
        .where('fromUid', isEqualTo: _myUid)
        .where('toUid', isEqualTo: toUid)
        .where('status', isEqualTo: 'pending')
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) throw Exception('Request already sent');

    await _db.collection('contactRequests').add({
      'fromUid': _myUid,
      'fromUsername': myUsername,
      'toUid': toUid,
      'toUsername': toUsername,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> incomingRequestsStream() {
    return _db
        .collection('contactRequests')
        .where('toUid', isEqualTo: _myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  Future<void> acceptRequest(String requestId, String fromUid, String fromUsername) async {
    final myProfile = await _db.collection('users').doc(_myUid).get();
    final myUsername = (myProfile.data()?['username'] as String?) ?? '';

    final batch = _db.batch();
    batch.update(_db.collection('contactRequests').doc(requestId), {'status': 'accepted'});
    batch.set(_db.collection('users').doc(_myUid).collection('contacts').doc(fromUid), {
      'username': fromUsername,
      'addedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('users').doc(fromUid).collection('contacts').doc(_myUid), {
      'username': myUsername,
      'addedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<void> declineRequest(String requestId) {
    return _db.collection('contactRequests').doc(requestId).update({'status': 'declined'});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> contactsStream() {
    return _db
        .collection('users')
        .doc(_myUid)
        .collection('contacts')
        .orderBy('username')
        .snapshots();
  }

  Future<void> removeContact(String contactUid) async {
    final batch = _db.batch();
    batch.delete(_db.collection('users').doc(_myUid).collection('contacts').doc(contactUid));
    batch.delete(_db.collection('users').doc(contactUid).collection('contacts').doc(_myUid));
    await batch.commit();
  }
}
