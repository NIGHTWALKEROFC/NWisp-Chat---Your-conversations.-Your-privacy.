import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ContactService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _myUid => _auth.currentUser!.uid;

  /// Looks up one person's current username straight from their public
  /// profile. Used wherever a saved contact name turns out to be empty.
  /// Returns 'Unknown' only if the person truly has no username.
  Future<String> usernameFor(String uid) async {
    try {
      final doc = await _db.collection('users').doc(uid).get();
      final name = (doc.data()?['username'] as String?)?.trim() ?? '';
      return name.isEmpty ? 'Unknown' : name;
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<String> _myUsername() async {
    final doc = await _db.collection('users').doc(_myUid).get();
    return (doc.data()?['username'] as String?)?.trim() ?? '';
  }

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
        // Feature: deactivated/suspended accounts show as "not found",
        // the same way Instagram hides a deactivated profile from
        // search — see AccountLifecycleService.setSelfDisabled and
        // MODERATION_GUIDE.md for where this flag actually gets set.
        // Missing entirely (an account from before this feature existed)
        // is treated as active, not hidden.
        .where((d) => (d.data()['isActive'] as bool?) ?? true)
        .map((d) => {'uid': d.id, ...d.data()})
        .toList();
  }

  // ---------------------------------------------------------------------
  // Feature: "People on NWisp" (Discover). Only people who switched
  // "Show me in suggestions" on (see AuthService.setDiscoverable) appear.
  // ---------------------------------------------------------------------

  /// A shuffled batch of people who opted in, minus myself, my contacts,
  /// people I already asked, and deactivated accounts. One simple equality
  /// query — needs no Firestore index.
  Future<List<Map<String, dynamic>>> discoverUsers({int limit = 80}) async {
    final snap = await _db.collection('users').where('discoverable', isEqualTo: true).limit(limit).get();
    final contacts = await myContactUids();
    final pending = await myPendingOutgoingUids();
    final result = <Map<String, dynamic>>[];
    for (final d in snap.docs) {
      if (d.id == _myUid) continue;
      if (contacts.contains(d.id)) continue;
      final data = d.data();
      if (!((data['isActive'] as bool?) ?? true)) continue;
      final name = (data['username'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      result.add({'uid': d.id, 'pending': pending.contains(d.id), ...data});
    }
    result.shuffle();
    return result;
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

    // If they already asked ME, tell the person instead of creating a
    // confusing second request in the other direction.
    final reverse = await _db
        .collection('contactRequests')
        .where('fromUid', isEqualTo: toUid)
        .where('toUid', isEqualTo: _myUid)
        .where('status', isEqualTo: 'pending')
        .limit(1)
        .get();
    if (reverse.docs.isNotEmpty) {
      throw Exception('They already sent you a request — accept it in the Requests tab.');
    }

    // A blank name is what made contacts show as "?" / Unknown. Always
    // resolve a real one before saving it into a request.
    final mine = myUsername.trim().isNotEmpty ? myUsername.trim() : await _myUsername();
    final theirs = toUsername.trim().isNotEmpty ? toUsername.trim() : await usernameFor(toUid);

    await _db.collection('contactRequests').add({
      'fromUid': _myUid,
      'fromUsername': mine,
      'toUid': toUid,
      'toUsername': theirs,
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

  /// Feature: request badge — how many people are waiting for me to answer.
  Stream<int> pendingRequestCountStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(0);
    return _db
        .collection('contactRequests')
        .where('toUid', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((s) => s.docs.length)
        .handleError((_) {});
  }

  Future<void> acceptRequest(String requestId, String fromUid, String fromUsername) async {
    final myUsername = await _myUsername();
    final theirName = fromUsername.trim().isNotEmpty ? fromUsername.trim() : await usernameFor(fromUid);

    final batch = _db.batch();
    batch.update(_db.collection('contactRequests').doc(requestId), {'status': 'accepted'});
    batch.set(_db.collection('users').doc(_myUid).collection('contacts').doc(fromUid), {
      'username': theirName == 'Unknown' ? '' : theirName,
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

  /// Looks up a single user by uid — used by the QR-code add-contact flow
  /// (see QrCodeScreen), since a scanned code encodes the other person's
  /// uid directly rather than something you'd type into [searchUsers].
  Future<Map<String, dynamic>?> userByUid(String uid) async {
    if (uid == _myUid) return null;
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    // Same "not found" treatment as searchUsers above — see its comment.
    if (!((doc.data()?['isActive'] as bool?) ?? true)) return null;
    return {'uid': doc.id, ...?doc.data()};
  }

  /// Feature: unfriend. Removes the person from BOTH contact lists. Nobody
  /// is notified, and the existing chat is left alone.
  Future<void> removeContact(String contactUid) async {
    final batch = _db.batch();
    batch.delete(_db.collection('users').doc(_myUid).collection('contacts').doc(contactUid));
    batch.delete(_db.collection('users').doc(contactUid).collection('contacts').doc(_myUid));
    await batch.commit();
  }
}
