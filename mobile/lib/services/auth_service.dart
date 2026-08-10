import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  /// Emits whenever the signed-in user changes (login, logout, token refresh).
  /// AuthGate listens to this to decide which screen to show at launch.
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
      'emailVisible': false,
      'phoneVisible': false,
      'lastSeenVisible': true,
      'readReceiptsEnabled': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(username.toLowerCase()), {'uid': cred.user!.uid});
    await batch.commit();

    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<void> logout() => _auth.signOut();

  /// Firebase requires a recent login before sensitive changes
  /// (email, password). Call this right before updateEmail/updatePassword
  /// if the user hasn't signed in recently, or Firebase throws
  /// `requires-recent-login`.
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

  /// Sends a verification link to the new address; the email only changes
  /// once the user clicks it. This is the current Firebase-recommended flow
  /// (the older, instant `updateEmail` is deprecated for security reasons).
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

  /// Phone number here is a profile field (shown to contacts, used for
  /// recovery) — not yet a sign-in method. See README note on Phone sign-in.
  Future<void> updatePhoneNumber(String phoneNumber) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({'phoneNumber': phoneNumber});
  }

  /// Renames the user, keeping the `usernames` uniqueness collection in sync.
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
}
