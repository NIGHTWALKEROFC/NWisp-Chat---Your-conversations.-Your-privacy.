import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'crypto_service.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  /// Set right after a successful sign-in or sign-up; the home screen reads
  /// and clears this once to show a one-time welcome / welcome-back toast.
  static String? pendingWelcomeMessage;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;

  /// Real-time-ish username availability check for the signup flow.
  Future<bool> isUsernameAvailable(String username) async {
    final lower = username.trim().toLowerCase();
    if (lower.isEmpty) return false;
    final doc = await _db.collection('usernames').doc(lower).get();
    return !doc.exists;
  }

  /// Best-effort email availability check. Firebase's own enumeration
  /// protection means this can come back inconclusive (empty list even for
  /// a registered email) — treat a "taken" result as reliable, but don't
  /// treat "looks available" as a guarantee. The real check still happens
  /// at account creation, which surfaces a friendly error either way.
  Future<bool> isEmailLikelyAvailable(String email) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty) return false;
    try {
      final methods = await _auth.fetchSignInMethodsForEmail(trimmed);
      return methods.isEmpty;
    } catch (_) {
      return true;
    }
  }

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
      'lastLoginAt': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(username.toLowerCase()), {'uid': cred.user!.uid});
    await batch.commit();

    // Best-effort — the account still works even if this fails (e.g. no
    // network right at that instant); it's not required for sign-in.
    try {
      await cred.user!.sendEmailVerification();
    } catch (_) {}

    pendingWelcomeMessage = 'Welcome to NWisp, $username! 🎉';
    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    // Make sure this device has keys even if the account was created
    // elsewhere or before this migration — publishes/refreshes publicKey.
    final publicKey = await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();

    final userRef = _db.collection('users').doc(cred.user!.uid);
    final snap = await userRef.get();
    final lastLoginAt = (snap.data()?['lastLoginAt'] as Timestamp?)?.toDate();
    final username = (snap.data()?['username'] as String?) ?? '';
    if (lastLoginAt != null && DateTime.now().difference(lastLoginAt).inDays >= 7) {
      pendingWelcomeMessage = 'Welcome back${username.isNotEmpty ? ', $username' : ''}! 👋';
    } else {
      pendingWelcomeMessage = null;
    }

    await userRef.set({
      'publicKey': publicKey,
      'lastLoginAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
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
