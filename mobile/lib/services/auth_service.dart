import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String username,
    required Map<String, dynamic> deviceKeys,
  }) async {
    final existing = await _db.collection('usernames').doc(username.toLowerCase()).get();
    if (existing.exists) throw Exception('Username already taken');

    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);

    final batch = _db.batch();
    batch.set(_db.collection('users').doc(cred.user!.uid), {
      'username': username,
      'usernameLower': username.toLowerCase(),
      'emailVisible': false,
      'phoneVisible': false,
      'lastSeenVisible': true,
      'readReceiptsEnabled': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(username.toLowerCase()), {'uid': cred.user!.uid});
    batch.set(
      _db.collection('users').doc(cred.user!.uid).collection('devices').doc('1'),
      {
        'identityKey': deviceKeys['identityKey'],
        'signedPrekey': deviceKeys['signedPrekey'],
        'signedPrekeySignature': deviceKeys['signedPrekeySignature'],
        'registrationId': deviceKeys['registrationId'],
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    await batch.commit();

    if (deviceKeys['oneTimePrekeys'] != null) {
      for (final otk in deviceKeys['oneTimePrekeys']) {
        await _db
            .collection('users').doc(cred.user!.uid)
            .collection('devices').doc('1')
            .collection('oneTimePrekeys').doc(otk['keyId'].toString())
            .set({'publicKey': otk['publicKey'], 'used': false});
      }
    }
    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<void> logout() => _auth.signOut();

  String? get currentUserId => _auth.currentUser?.uid;
}
