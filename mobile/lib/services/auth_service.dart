import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
    String? phoneNumber,
  }) async {
    final existing = await _db.collection('usernames').doc(username.toLowerCase()).get();
    if (existing.exists) throw Exception('Username already taken');

    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);

    final batch = _db.batch();
    batch.set(_db.collection('users').doc(cred.user!.uid), {
      'username': username,
      'usernameLower': username.toLowerCase(),
      'phoneNumber': phoneNumber,
      'photoUrl': null,
      'emailVisible': false,
      'phoneVisible': false,
      'lastSeenVisible': true,
      'readReceiptsEnabled': true,
      'online': false,
      'lastSeen': FieldValue.serverTimestamp(),
      'blockedUsers': <String>[],
      'messageTtlHours': 24,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(username.toLowerCase()), {'uid': cred.user!.uid});
    await batch.commit();

    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

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

  Future<void> updatePhoneNumber(String phoneNumber) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({'phoneNumber': phoneNumber});
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

  Future<void> startPhoneVerification({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(String message) onFailed,
    void Function(PhoneAuthCredential credential)? onAutoVerified,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) {
        if (onAutoVerified != null) onAutoVerified(credential);
      },
      verificationFailed: (e) => onFailed(e.message ?? 'Phone verification failed'),
      codeSent: (verificationId, _) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  PhoneAuthCredential resolvePhoneCode({required String verificationId, required String smsCode}) {
    return PhoneAuthProvider.credential(verificationId: verificationId, smsCode: smsCode);
  }

  Future<void> linkAndSavePhoneNumber({
    required PhoneAuthCredential credential,
    required String phoneNumber,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');

    final alreadyLinked = user.providerData.any((p) => p.providerId == 'phone');
    if (alreadyLinked) {
      await user.unlink('phone');
    }
    await user.linkWithCredential(credential);
    await _db.collection('users').doc(user.uid).update({'phoneNumber': phoneNumber});
  }

  Future<void> sendPasswordResetEmail(String email) => _auth.sendPasswordResetEmail(email: email);

  Future<void> signInWithPhoneCredential(PhoneAuthCredential credential) {
    return _auth.signInWithCredential(credential);
  }
}
