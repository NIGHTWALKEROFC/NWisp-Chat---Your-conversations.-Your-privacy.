import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'device_session_service.dart';
import 'presence_service.dart';
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

  // ---------------------------------------------------------------------
  // Feature: custom-branded, non-spam email flow (signup OTP + a branded
  // "reset your password" button) — see EMAIL_SETUP.md for the full
  // picture and supabase/functions/ for the four Edge Functions this
  // calls. Same "derive from the SUPABASE_URL build-time define" pattern
  // MediaService already uses for get-signed-url, so this automatically
  // follows whichever Supabase project the app was built against.
  // ---------------------------------------------------------------------

  static String get _functionsBase => '${const String.fromEnvironment('SUPABASE_URL')}/functions/v1';

  /// Posts to one of the email Edge Functions and returns its decoded
  /// JSON body. Throws an [Exception] carrying the server's own `error`
  /// message when the call fails, so screens can show it directly (same
  /// spirit as MediaService's `_throwWithDetail`, minus the 404-specific
  /// deploy-reminder text since that lives there already).
  static Future<Map<String, dynamic>> _postFunction(
    String name,
    Map<String, dynamic> body, {
    bool includeIdToken = false,
  }) async {
    final headers = {'Content-Type': 'application/json'};
    if (includeIdToken) {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('No signed-in user');
      final idToken = await user.getIdToken();
      headers['Authorization'] = 'Bearer $idToken';
    }
    final res = await http.post(
      Uri.parse('$_functionsBase/$name'),
      headers: headers,
      body: jsonEncode(body),
    );
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      decoded = <String, dynamic>{};
    }
    if (res.statusCode != 200) {
      final message = decoded['error'] as String?;
      if (res.statusCode == 404) {
        throw Exception(
          "$name failed (HTTP 404): that Edge Function isn't deployed on this "
          'Supabase project yet — see EMAIL_SETUP.md for the one-time deploy steps.',
        );
      }
      throw Exception(message ?? '$name failed (HTTP ${res.statusCode}).');
    }
    return decoded;
  }

  /// Step 1 of the Instagram-style signup flow — sends a 6-digit code to
  /// [email] via our own branded email (not Firebase's default one). Safe
  /// to call again for the same email; the server enforces its own
  /// resend cooldown and surfaces that as the thrown message.
  /// Sends the code with this device's persisted id attached (see
  /// DeviceSessionService._localDeviceId) so the server's abuse
  /// throttle can key on device as well as IP — see send-signup-otp's
  /// own comments for why that matters (switching WiFi alone no longer
  /// resets a block).
  Future<void> sendSignupOtp(String email) async {
    final deviceId = await DeviceSessionService.instance.localDeviceId();
    await _postFunction('send-signup-otp', {'email': email, 'deviceId': deviceId});
  }

  /// Step 2 — checks [code] against what was emailed for [email]. Throws
  /// with a friendly message ("Incorrect code", "That code expired", …)
  /// on failure; returns normally on success.
  Future<void> verifySignupOtp(String email, String code) =>
      _postFunction('verify-signup-otp', {'email': email, 'code': code});

  /// Step 3 — called right after the Firebase Auth account is actually
  /// created (from [registerWithEmail] below). Redeems the verification
  /// from step 2 and marks the new account's email verified server-side.
  /// Deliberately best-effort: the account still works even if this
  /// fails (e.g. no network right at that instant), it just won't show
  /// as verified — same tolerance the old sendEmailVerification() call
  /// had for the same reason.
  Future<void> _confirmVerifiedEmail() async {
    try {
      final deviceId = await DeviceSessionService.instance.localDeviceId();
      await _postFunction('confirm-verified-email', {'deviceId': deviceId}, includeIdToken: true);
    } catch (_) {}
  }

  /// Instagram-style "forgot password": accepts either an email OR a
  /// username (resolved server-side — see send-password-reset), and
  /// emails a branded button that opens a page where the person types a
  /// new password directly, instead of Firebase's default bare
  /// confirmation link — or, when [method] is 'otp', a 6-digit code
  /// instead. Returns the raw {mode, message} map (mode = what the
  /// server ACTUALLY sent) so the screen can show the right follow-up UI.
  ///
  /// HONESTY NOTE: unlike a typical "forgot password" endpoint, this one
  /// DOES tell the caller outright if no account matches — a deliberate
  /// product choice (see send-password-reset's own comment for the
  /// trade-off), not an oversight.
  ///
  /// [method] is what the person picked on the Reset password screen:
  /// 'otp' (a 6-digit code) or 'email' (a link). The screen now ALWAYS asks —
  /// nothing is decided for them — so this is passed on every call. When it's
  /// omitted the server falls back to emailing the link.
  Future<Map<String, dynamic>> requestPasswordReset(String identifier, {String? method}) async {
    final deviceId = await DeviceSessionService.instance.localDeviceId();
    return _postFunction('send-password-reset', {
      'identifier': identifier,
      'deviceId': deviceId,
      if (method != null) 'method': method,
    });
  }

  /// Checks a reset code WITHOUT using it up or changing anything, so the
  /// reset screen can turn the code boxes green (right) or red (wrong) the
  /// moment the last digit is typed — before asking for the new password.
  /// Throws with the server's message on a wrong or expired code.
  Future<void> checkPasswordResetOtp({required String email, required String code}) =>
      _postFunction('verify-password-reset-otp', {'email': email, 'code': code});

  /// Second half of the OTP-based reset: checks [code] against what was
  /// emailed for [email], and if correct, sets [newPassword] directly —
  /// no Firebase email link involved in this path at all. Throws with a
  /// friendly message ("Incorrect code", "That code expired", …) on
  /// failure.
  Future<void> verifyPasswordResetOtp({
    required String email,
    required String code,
    required String newPassword,
  }) =>
      _postFunction('verify-password-reset-otp', {'email': email, 'code': code, 'newPassword': newPassword});

  /// Settings -> Account security -> "Password reset method". 'email'
  /// (the default) or 'otp'. Written straight to the owner-only private
  /// profile doc — same pattern as [updatePrivacySetting] — so
  /// send-password-reset can read it server-side the next time this
  /// account's owner requests a reset.
  Future<void> updatePasswordResetMethod(String method) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _privateProfileRef(uid).set({'passwordResetMethod': method}, SetOptions(merge: true));
  }

  Future<String> currentPasswordResetMethod() async {
    final snap = await currentUserPrivateProfile();
    return (snap.data()?['passwordResetMethod'] as String?) ?? 'email';
  }

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

    // Feature: Instagram-style signup — by this point the person already
    // typed the email, got a 6-digit code emailed to them, and confirmed
    // it (see RegisterScreen's email + verify steps, and sendSignupOtp /
    // verifySignupOtp above). This is the step that redeems that
    // confirmation onto the account we JUST created, flipping
    // emailVerified to true server-side. Replaces the old
    // cred.user!.sendEmailVerification() call — there's no separate
    // "click a link to confirm" email anymore, the code they already
    // entered during signup *is* the confirmation.
    await _confirmVerifiedEmail();

    pendingWelcomeMessage = 'Welcome to NWisp, $lowerUsername! 🎉';
    await DeviceSessionService.instance.claimThisDevice(cred.user!.uid);
    return cred;
  }

  /// Step 1 of signing in: verify credentials only. Always call this
  /// first, regardless of whether the account has "Require approval for
  /// new logins" turned on — the caller (LoginScreen) checks
  /// [DeviceSessionService.isLoginApprovalRequired] with the returned uid
  /// and either calls [finishLogin] right away (approval OFF, unchanged
  /// behavior) or runs the approval wait first (see LoginScreen._login).
  ///
  /// Deliberately does NOT call SessionService.prepareForUser or
  /// DeviceSessionService.claimThisDevice — those still only happen in
  /// [finishLogin], once any required approval has actually been
  /// granted, so a denied/timed-out login never touches this device's
  /// local crypto state or claims the account's active-device slot.
  Future<String> beginEmailLogin(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    return cred.user!.uid;
  }

  /// Feature: failed-login lockout. Call BEFORE [beginEmailLogin] — throws
  /// if this device/network is currently locked out from previous
  /// failures, so LoginScreen never even attempts the Firebase sign-in
  /// call in that case. Fails OPEN on its own errors (network hiccup
  /// reaching login-guard, etc.) — a bug in this check should never be
  /// able to lock someone out who isn't actually blocked.
  Future<void> checkLoginLockout() async {
    try {
      final deviceId = await DeviceSessionService.instance.localDeviceId();
      final data = await _postFunction('login-guard', {'action': 'check', 'deviceId': deviceId});
      if (data['blocked'] == true) {
        throw Exception((data['message'] as String?) ?? 'Too many failed sign-in attempts. Try again later.');
      }
    } on Exception catch (e) {
      if (e.toString().contains('Too many failed sign-in attempts')) rethrow;
      // Any other failure (network, function not deployed yet, etc.) —
      // fail open rather than block a legitimate sign-in over it.
    }
  }

  /// Feature: failed-login lockout. Call after [beginEmailLogin] throws
  /// with wrong credentials — logs the failure against both this
  /// device/network (escalating block) and the account itself (for the
  /// "10+ attempts from everywhere" Account Security warning). Always
  /// best-effort: never throws, never blocks showing the person their
  /// own "incorrect password" message.
  Future<void> recordLoginFailure(String email) async {
    try {
      final deviceId = await DeviceSessionService.instance.localDeviceId();
      await _postFunction('login-guard', {'action': 'record_failure', 'email': email, 'deviceId': deviceId});
    } catch (_) {}
  }

  /// Feature: failed-login lockout. How many failed attempts have been
  /// logged against THIS signed-in account in the last 7 days,
  /// regardless of which device/network they came from — shown as a
  /// warning banner in Account Security when 10 or higher. Fails
  /// silently to 0 rather than throwing, since this is informational,
  /// not something that should ever break the settings screen.
  Future<int> recentLoginFailureCount() async {
    try {
      final data = await _postFunction('login-failure-count', {}, includeIdToken: true);
      return (data['count'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Step 2 (only reached if login-approval was required and was denied,
  /// timed out, or was cancelled by the person waiting): undoes step 1's
  /// Firebase Auth sign-in so this device is fully back to "signed out",
  /// not left in a half-signed-in state.
  Future<void> abortLogin() => _auth.signOut();

  /// Step 2 (the normal case — approval wasn't required, or it was
  /// granted): everything [loginWithEmail] used to do inline, now run
  /// once as a distinct step so the approval wait in between never has to
  /// touch local crypto state or the active-device slot until it's
  /// actually earned that.
  Future<void> finishLogin(String uid) async {
    // Prepares (and, if this device last belonged to a different account,
    // wipes-then-prepares) this device's Signal Protocol identity and local
    // message store, AND migrates any pre-restructure account onto the new
    // private/profile + private/presence documents (see
    // SessionService._ensurePrivateDocs).
    await SessionService.prepareForUser(uid);

    final profileSnap = await _privateProfileRef(uid).get();
    final lastLoginAt = (profileSnap.data()?['lastLoginAt'] as Timestamp?)?.toDate();
    final userDoc = await _db.collection('users').doc(uid).get();
    final username = (userDoc.data()?['username'] as String?) ?? '';
    if (lastLoginAt != null && DateTime.now().difference(lastLoginAt).inDays >= 7) {
      pendingWelcomeMessage = 'Welcome back${username.isNotEmpty ? ', $username' : ''}! 👋';
    } else {
      pendingWelcomeMessage = null;
    }

    await _privateProfileRef(uid).set({'lastLoginAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    // Makes this device the account's sole active device — any other
    // device previously signed in gets signed out (see
    // DeviceSessionService and its listener wired up in main.dart).
    await DeviceSessionService.instance.claimThisDevice(uid);
  }

  /// Unchanged end-to-end behavior for the common case (login-approval
  /// toggle OFF) — just [beginEmailLogin] immediately followed by
  /// [finishLogin]. LoginScreen calls the two steps directly instead of
  /// this method only when it needs to insert the approval wait between
  /// them; kept here so any other/future caller that doesn't care about
  /// that flow can still call one simple method.
  Future<UserCredential> loginWithEmail(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    await finishLogin(cred.user!.uid);
    return cred;
  }

  Future<void> logout() async {
    // BUGFIX: without this, this device's FCM token stayed in the account's
    // fcmTokens list after logout — so if someone logged into a DIFFERENT
    // account on the same device afterwards, this device could keep
    // getting the FIRST account's push notifications too.
    final uid = currentUserId;
    if (uid != null) {
      // BUGFIX (login approval): sign-out used to leave this phone marked
      // "online" and as the account's "active device". For the next few
      // minutes any new login was then told to wait for an approval from a
      // phone that was no longer signed in — and nobody could ever answer.
      // Now a normal sign-out marks the account offline and releases this
      // phone's active-device claim first. (If this sign-out is a forced one
      // because ANOTHER phone took over, the claim isn't ours any more, so
      // releaseActiveClaimIfMine correctly leaves it alone.)
      try {
        await PresenceService.goOffline();
      } catch (_) {}
      try {
        await DeviceSessionService.instance.releaseActiveClaimIfMine(uid);
      } catch (_) {}
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) await removeFcmToken(token);
      } catch (_) {
        // Not worth blocking sign-out over — worst case one stale token
        // lingers until FCM reports it dead or the account is used again.
      }
    }
    await _auth.signOut();
    DeviceSessionService.instance.stopWatching();
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

  /// Feature: notifies BOTH the current email and [newEmail] the moment
  /// this is requested — see notify-email-change's own comments for why
  /// (the current/old address is the one that matters most: if this
  /// wasn't the real owner requesting it, they need to hear about it
  /// from an address the attacker doesn't control). Best-effort: if the
  /// notification fails to send for some reason, the actual email
  /// change (Firebase's own verifyBeforeUpdateEmail flow, unchanged
  /// below) still proceeds — a notification failing shouldn't block the
  /// legitimate feature.
  Future<void> requestEmailChange(String newEmail) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');
    try {
      await _postFunction('notify-email-change', {'newEmail': newEmail}, includeIdToken: true);
    } catch (_) {}
    await user.verifyBeforeUpdateEmail(newEmail);
  }

  Future<void> updatePassword(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');
    await user.updatePassword(newPassword);
    await DeviceSessionService.instance.logPasswordChanged(user.uid);
  }

  Future<void> updatePhotoUrl(String photoUrl) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    await _db.collection('users').doc(uid).update({'photoUrl': photoUrl});
  }

  /// Feature: "Who can add me" — controls whether OTHER people can put you
  /// straight into a group (no confirmation) or must always send you a
  /// request first. Lives on the PUBLIC `users/{uid}` doc (like username or
  /// photoUrl) rather than the owner-only private profile, because whoever
  /// is about to add someone has to be able to read their choice before
  /// deciding whether to add directly or send a request — see
  /// GroupService.addOrInviteMember, which is what actually enforces this.
  ///
  /// One of: 'contacts' (default — unchanged from the app's original
  /// behavior: your contacts can add you directly, anyone else must
  /// request), 'requests' (nobody can add you directly, not even
  /// contacts — everyone must send a request you accept), or 'nobody' (no
  /// one can add or request to add you to a new group at all).
  ///
  /// Communities are unaffected either way: nobody "adds" you to a
  /// Community — you always find and join one yourself from the Community
  /// tab, so there is nothing here for this setting to restrict.
  Future<void> updateWhoCanInviteMe(String value) async {
    final uid = currentUserId;
    if (uid == null) throw Exception('No signed-in user');
    assert(['contacts', 'requests', 'nobody'].contains(value));
    await _db.collection('users').doc(uid).update({'whoCanInviteMe': value});
  }

  Future<String> whoCanInviteMeFor(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    return (doc.data()?['whoCanInviteMe'] as String?) ?? 'contacts';
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
}
