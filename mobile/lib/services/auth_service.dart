import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'session_service.dart';

/// Field-level privacy note (see firestore.rules): the public `users/{uid}`
/// doc only ever holds username/photoUrl/publicKey now - anything private
/// (blockedUsers, messageTtlHours, readReceiptsEnabled, lastSeenVisible,
/// fcmTokens, lastLoginAt) lives in the owner-only `users/{uid}/private/profile`
/// doc. `online`/`lastSeen` live in `users/{uid}/private/presence`, which has
/// its own rule that only allows other people to read it when the owner has
/// last-seen sharing on AND hasn't blocked them.
class AuthService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  /// Set right after a successful sign-in or sign-up; the home screen reads
  /// and clears this once to show a one-time welcome / welcome-back toast.
  static String? pendingWelcomeMessage;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _privateProfileRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('profile');

  DocumentReference<Map<String, dynamic>> _presenceRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('presence');

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
    // Usernames are lowercase-only from here on (Instagram-style — the
    // signup screen already forces lowercase as you type, this is just a
    // server-side guarantee). Existing accounts created before this change
    // keep whatever casing they already have; nothing here touches them.
    final lowerUsername = username.trim().toLowerCase();

    final existing = await _db.collection('usernames').doc(lowerUsername).get();
    if (existing.exists) throw Exception('Username already taken');

    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    // SessionService both prepares this device's Signal Protocol identity
    // AND — if a different account was last active on this device — wipes
    // that previous account's local state first (old messages, old keys)
    // so it's never visible to this new one.
    await SessionService.prepareForUser(cred.user!.uid);

    final batch = _db.batch();
    batch.set(_db.collection('users').doc(cred.user!.uid), {
      'username': lowerUsername,
      'usernameLower': lowerUsername,
      'photoUrl': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_privateProfileRef(cred.user!.uid), {
      'emailVisible': false,
      'lastSeenVisible': true,
      'readReceiptsEnabled': true,
      'blockedUsers': <String>[],
      'messageTtlHours': 0, // never auto-delete — disappearing messages are opt-in (see settings_screen.dart)
      'fcmTokens': <String>[],
      'lastLoginAt': FieldValue.serverTimestamp(),
    });
    batch.set(_presenceRef(cred.user!.uid), {
      'online': false,
      'lastSeen': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('usernames').doc(lowerUsername), {'uid': cred.user!.uid});
    // BUGFIX: registration used to call batch.commit() with nothing
    // guarding it. The initial "is this username taken" check above and
    // the actual reservation here are two separate round-trips, so two
    // people signing up with the same username at nearly the same moment
    // could both pass the check and both reach this point. Firestore's
    // security rules correctly reject the *second* writer's `usernames`
    // create (it's a create-only doc), which fails the whole batch — but
    // by then their Firebase Auth account already exists. Without this
    // try/catch, that user would be left with a working Auth login and no
    // Firestore profile document at all, breaking the app for them
    // permanently. Now we delete the just-created Auth account and surface
    // a clear, retryable error instead.
    try {
      await batch.commit();
    } catch (e) {
      try {
        await cred.user!.delete();
      } catch (_) {
        // Best-effort cleanup — if this also fails (e.g. requires recent
        // login, which it doesn't right after creation, or no network),
        // the account may still be orphaned. Rare, but surfacing the
        // original error is still the right call either way.
      }
      throw Exception('That username was just taken by someone else — please choose another and try again.');
    }

    // Best-effort — the account still works even if this fails (e.g. no
    // network right at that instant); it's not required for sign-in.
    try {
      await cred.user!.sendEmailVerification();
    } catch (_) {}

    pendingWelcomeMessage = 'Welcome to NWisp, $lowerUsername! 🎉';
    return cred;
  }

  Future<UserCredential> loginWithEmail(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    // Prepares (and, if this device last belonged to a different account,
    // wipes-then-prepares) this device's Signal Protocol identity and local
    // message store, AND migrates any pre-restructure account onto the new
    // private/profile + private/presence documents (see
    // SessionService._ensurePrivateDocs).
    await SessionService.prepareForUser(cred.user!.uid);

    final profileSnap = await _privateProfileRef(cred.user!.uid).get();
    final lastLoginAt = (profileSnap.data()?['lastLoginAt'] as Timestamp?)?.toDate();
    final userDoc = await _db.collection('users').doc(cred.user!.uid).get();
    final username = (userDoc.data()?['username'] as String?) ?? '';
    if (lastLoginAt != null && DateTime.now().difference(lastLoginAt).inDays >= 7) {
      pendingWelcomeMessage = 'Welcome back${username.isNotEmpty ? ', $username' : ''}! 👋';
    } else {
      pendingWelcomeMessage = null;
    }

    await _privateProfileRef(cred.user!.uid).set({'lastLoginAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    return cred;
  }

  Future<void> logout() async {
    // BUGFIX: without this, this device's FCM token stayed in the account's
    // fcmTokens list after logout — so if someone logged into a DIFFERENT
    // account on the same device afterwards, this device could keep
    // getting the FIRST account's push notifications too.
    final uid = currentUserId;
    if (uid != null) {
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) await removeFcmToken(token);
      } catch (_) {
        // Not worth blocking sign-out over — worst case one stale token
        // lingers until FCM reports it dead or the account is used again.
      }
    }
    await _auth.signOut();
  }

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

  /// Public profile only (username, photoUrl, publicKey). For your own
  /// private settings (blockedUsers, messageTtlHours, readReceiptsEnabled,
  /// lastSeenVisible, fcmTokens) use [currentUserPrivateProfile] instead.
  Future<DocumentSnapshot<Map<String, dynamic>>> currentUserProfile() {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    return _db.collection('users').doc(uid).get();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> currentUserPrivateProfile() {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    return _privateProfileRef(uid).get();
  }

  Future<void> updatePrivacySetting(String field, bool value) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _privateProfileRef(uid).set({field: value}, SetOptions(merge: true));
  }

  Future<void> updateMessageTtl(int hours) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _privateProfileRef(uid).set({'messageTtlHours': hours}, SetOptions(merge: true));
  }

  Future<void> saveFcmToken(String token) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _privateProfileRef(uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }

  Future<void> removeFcmToken(String token) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _privateProfileRef(uid).set({
      'fcmTokens': FieldValue.arrayRemove([token]),
    }, SetOptions(merge: true));
  }

  Future<void> sendPasswordResetEmail(String email) => _auth.sendPasswordResetEmail(email: email);
}
