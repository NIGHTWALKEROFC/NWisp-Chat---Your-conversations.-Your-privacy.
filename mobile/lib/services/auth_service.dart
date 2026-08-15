import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'crypto_service.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;

  Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String username,
  }) async {
    final existing = await _db.collection('usernames').doc(username.toLowerCase()).get();
    if (existing.exists) throw Exception('Username already taken');

    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    final publicKey = await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();

    final batch = _db.batch();
    batch.set(_db.collection('users').doc(cred.user!.uid), {
      'username': username,
      'usernameLower': username.toLowerCase(),
      'photoUrl': null,
      'emailVisible': false,
      'lastSeenVisible': true,
      'readReceiptsEnabled': true,
      'online': false,
      'lastSeen': FieldValue.serverTimestamp(),
      'blockedUsers': <String>[],
      'messageTtlHours': 24,
      'publicKey': publicKey,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(username.toLowerCase()), {'uid': cred.user!.uid});
    await batch.commit();

    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    // Make sure this device has keys even if the account was created
    // elsewhere or before this migration — publishes/refreshes publicKey.
    final publicKey = await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();
    await _db.collection('users').doc(cred.user!.uid).set({'publicKey': publicKey}, SetOptions(merge: true));
    return cred;
  }

  Future<void> logout() => _auth.signOut();

  Future<void> reauthenticate(String currentPassword) async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) {
      throw Exception('No signed-in user');
    }
    final credential = EmailAuthProvider.credential(
      email: user.email!,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
  }

  Future<void> requestEmailChange(String newEmail) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');
    await user.verifyBeforeUpdateEmail(newEmail);
  }

  Future<void> updatePassword(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');
    await user.updatePassword(newPassword);
  }

  Future<void> updatePhotoUrl(String photoUrl) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({'photoUrl': photoUrl});
  }

  Future<void> updateUsername(String newUsername) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    final newLower = newUsername.toLowerCase();

    final userDoc = await _db.collection('users').doc(uid).get();
    final oldLower = (userDoc.data()?['usernameLower'] as String?) ?? '';
    if (newLower == oldLower) return;

    final existing = await _db.collection('usernames').doc(newLower).get();
    if (existing.exists) throw Exception('Username already taken');

    final batch = _db.batch();
    if (oldLower.isNotEmpty) {
      batch.delete(_db.collection('usernames').doc(oldLower));
    }
    batch.set(_db.collection('usernames').doc(newLower), {'uid': uid});
    batch.update(_db.collection('users').doc(uid), {
      'username': newUsername,
      'usernameLower': newLower,
    });
    await batch.commit();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> currentUserProfile() {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    return _db.collection('users').doc(uid).get();
  }

  Future<void> updatePrivacySetting(String field, bool value) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({field: value});
  }

  Future<void> updateMessageTtl(int hours) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({'messageTtlHours': hours});
  }

  Future<void> saveFcmToken(String token) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({
      'fcmTokens': FieldValue.arrayUnion([token]),
    });
  }

  Future<void> sendPasswordResetEmail(String email) => _auth.sendPasswordResetEmail(email: email);
}
