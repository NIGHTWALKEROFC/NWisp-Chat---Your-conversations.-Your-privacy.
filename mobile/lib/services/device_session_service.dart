import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'secure_storage_service.dart';

/// Enforces a single active device per account — logging in on a second
/// device signs the first one out, the same way WhatsApp/most banking
/// apps behave — and keeps a simple security-activity log (logins,
/// password changes, forced logouts) for the Account Security screen.
///
/// This is deliberately NOT full Signal-style simultaneous multi-device
/// support (separate E2E sessions fanning out to every device someone
/// owns) — that's a much larger undertaking on top of the Double Ratchet
/// work in Phase 5. Enforcing one active device at a time instead keeps
/// that existing single-device setup simple AND gives the actual security
/// benefit that was asked for: knowing about, and being able to end,
/// unexpected sign-ins.
class DeviceSessionService {
  DeviceSessionService._();
  static final instance = DeviceSessionService._();

  final _db = FirebaseFirestore.instance;
  StreamSubscription? _watchSub;
  String? _myDeviceId;

  // BUGFIX (regression fix): [watchForRemoteLogout] used to judge its very
  // first Firestore snapshot as-is. That snapshot can easily arrive BEFORE
  // this device's own [claimThisDevice] write has actually landed —
  // claimThisDevice does a device-info lookup, a network geolocation call
  // (up to 5s), and two Firestore writes before it's done. [_lastClaim]
  // originally covered this by letting [watchForRemoteLogout] wait for any
  // of THIS instance's own in-flight claims to finish before judging a
  // mismatch — which worked because the old, single-method login flow
  // called claimThisDevice essentially back-to-back with signing in, so
  // _lastClaim was reliably already set by the time any snapshot fired.
  //
  // Splitting login into beginEmailLogin()/finishLogin() (for the
  // new-login-approval feature) reopened this exact race: main.dart's
  // authStateChanges fires the INSTANT signInWithEmailAndPassword
  // succeeds — before claimThisDevice has even been called yet, let alone
  // finished. If approval is required, that gap can be up to the full
  // 60-second wait; even without it, it's however long finishLogin's own
  // async work takes. In that window, _lastClaim is still null (nothing
  // has called claimThisDevice yet to set it), so the old guard didn't
  // apply, watchForRemoteLogout read the stale activeDeviceId, and signed
  // the device right back out mid-login — the "immediately logs out" /
  // "need 2-3 tries to log in" bug, and (as a knock-on effect) very likely
  // also the cause of a suspended account's re-login attempt showing a
  // confusing generic sign-in error instead of ever reaching the
  // suspension screen, since the interrupted sign-in never got a chance
  // to finish normally.
  //
  // [isClaimPending] closes that whole window at the source: LoginScreen
  // sets it true for the ENTIRE span of a login attempt (from the moment
  // credentials are verified through claimThisDevice actually completing)
  // and false again once that's done, success or not. While true,
  // [watchForRemoteLogout] ignores any mismatch outright — it isn't a
  // real takeover, this device just legitimately hasn't claimed yet, on
  // purpose.
  //
  // BUGFIX (2nd round): the exact same premature-authStateChanges gap
  // ALSO reached AuthGate and _setUpMessagingLifecycle in main.dart —
  // signInWithEmailAndPassword (inside beginEmailLogin) makes Firebase
  // Auth report a signed-in user immediately, long before
  // isLoginApprovalRequired/createLoginApprovalRequest/claimThisDevice
  // ever run. AuthGate was reacting to that raw signal and jumping
  // straight to the main app UI before approval had even been asked
  // for, and _watchForIncomingLoginApprovals (also started right then)
  // was listening for pending approval requests on THIS SAME
  // still-logging-in device — so it would catch the request THIS device
  // itself had just created and pop the "approve this login" screen on
  // itself, asking the person to approve their own sign-in. Accepting
  // that self-prompt raced against LoginScreen's own approval listener
  // and AuthGate's premature switch, which is what actually caused
  // "need to approve/deny several times before it sticks."
  //
  // isClaimPending was a plain bool, which AuthGate's StreamBuilder had
  // no way to react to (it only rebuilds on new authStateChanges events,
  // and there isn't a fresh one just because this flag flipped). Backing
  // it with a ValueNotifier lets AuthGate listen for that flip directly
  // (see AuthGate's ValueListenableBuilder) so it now correctly holds on
  // LoginScreen for the entire login attempt — approval wait included —
  // and only proceeds to the real app once claimThisDevice has actually
  // finished. The public get/set below keep every existing call site
  // (`DeviceSessionService.instance.isClaimPending = true/false`, `if
  // (isClaimPending) return;`) working unchanged.
  final ValueNotifier<bool> claimPendingNotifier = ValueNotifier<bool>(false);
  bool get isClaimPending => claimPendingNotifier.value;
  set isClaimPending(bool value) => claimPendingNotifier.value = value;
  Future<void>? _lastClaim;

  DocumentReference<Map<String, dynamic>> _sessionRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('session');

  CollectionReference<Map<String, dynamic>> _historyRef(String uid) =>
      _sessionRef(uid).collection('history');

  /// New-login approval requests (see the "Require approval for new
  /// logins" toggle on AccountSecurityScreen). A subcollection of the
  /// same owner-only private/session doc used for device tracking, so it
  /// shares that doc's existing firestore.rules access.
  CollectionReference<Map<String, dynamic>> _approvalsRef(String uid) =>
      _sessionRef(uid).collection('loginApprovals');

  Future<String> _localDeviceId() async {
    if (_myDeviceId != null) return _myDeviceId!;
    final existing = await SecureStorageService.getDeviceId();
    if (existing != null) {
      _myDeviceId = existing;
      return existing;
    }
    final id = const Uuid().v4();
    await SecureStorageService.saveDeviceId(id);
    _myDeviceId = id;
    return id;
  }

  /// Public accessor for this device's own local id — used by main.dart to
  /// tell "a genuinely different device's login request" apart from "a
  /// pending request THIS device just created about itself" (see the
  /// self-approval bugfix in [claimPendingNotifier]'s doc comment and in
  /// main.dart's `_watchForIncomingLoginApprovals`).
  Future<String> localDeviceId() => _localDeviceId();

  String _deviceLabel(String deviceId) => 'Android phone (…${deviceId.substring(deviceId.length - 4)})';

  /// A real device model (e.g. "Samsung Galaxy S23", "Pixel 8") instead of
  /// the old generic placeholder above — makes the Account Security
  /// screen's login history actually useful for spotting a login that
  /// wasn't you, the same way Google's/WhatsApp's own "where you're
  /// signed in" lists do. [_deviceLabel] above is left in place unused by
  /// [claimThisDevice]/[logPasswordChanged] now, rather than deleted
  /// outright, since it's still a reasonable fallback shape if this ever
  /// needs one (e.g. a future non-Android build).
  Future<String> _realDeviceLabel() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final manufacturer = info.manufacturer.trim();
      final model = info.model.trim();
      if (model.isEmpty) return 'Android phone';
      // Some OEMs (Samsung, Xiaomi) already fold their brand into `model`
      // on some builds — avoid a redundant "Samsung Samsung Galaxy S23".
      if (manufacturer.isEmpty || model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
        return model;
      }
      return '$manufacturer $model';
    } catch (_) {
      return 'Android phone';
    }
  }

  /// Best-effort city/country for THIS login, from a free IP-geolocation
  /// lookup done entirely client-side — see the setup notes for why no
  /// server component is needed for this. Never blocks or fails a sign-in:
  /// any error here (no network, the free API being briefly unavailable,
  /// a slow response) just means this one login's history entry has no
  /// location on it, which the UI already handles by simply not showing
  /// that line rather than erroring.
  Future<String?> _locationLabel() async {
    try {
      final response = await http.get(Uri.parse('https://ipapi.co/json/')).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final city = (data['city'] as String?)?.trim();
      final country = (data['country_name'] as String?)?.trim();
      if (city != null && city.isNotEmpty && country != null && country.isNotEmpty) {
        return '$city, $country';
      }
      if (country != null && country.isNotEmpty) return country;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Real, server-verified IP address for THIS login/security event —
  /// deliberately separate from [_locationLabel] above, which is a
  /// best-effort city/country guess the device reports about itself.
  /// This instead asks the get-client-ip Edge Function, which reads the
  /// actual IP Supabase's own gateway saw the request come from — not
  /// something the device could get wrong or fake. Shown in Account
  /// Security's activity list so the account's real owner can tell
  /// "was this actually me?" apart for any login, the same way
  /// Instagram/Google's own "where you're signed in" lists show an IP.
  /// Never blocks or fails a sign-in — same best-effort tolerance as
  /// [_locationLabel]: any error here just means this one history entry
  /// has no IP on it.
  Future<String?> _realIp() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;
      final idToken = await user.getIdToken();
      final base = const String.fromEnvironment('SUPABASE_URL');
      final res = await http
          .get(
            Uri.parse('$base/functions/v1/get-client-ip'),
            headers: {'Authorization': 'Bearer $idToken'},
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['ip'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Call right after a successful sign-in/sign-up (see AuthService). Makes
  /// THIS device the one-and-only active device for the account — any
  /// other device that was previously active gets signed out next time its
  /// listener fires (see [watchForRemoteLogout]), typically within
  /// seconds if it's online, or the next time it's foregrounded otherwise.
  Future<void> claimThisDevice(String uid) {
    // Assigned synchronously, before any awaiting happens inside
    // [_claimThisDevice] — so [watchForRemoteLogout], however soon it
    // runs after this call starts, can always see that a claim is
    // in-flight and wait for it. See [_lastClaim]'s doc comment above.
    final future = _claimThisDevice(uid);
    _lastClaim = future;
    return future;
  }

  /// Feature: emails the account owner immediately on a new login —
  /// see send-security-alert's own comments. Best-effort, same
  /// tolerance as [_realIp]: never blocks or fails the login itself.
  Future<void> _sendSecurityAlert(String event, String? deviceLabel, String? location, String? ip) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final idToken = await user.getIdToken();
      final base = const String.fromEnvironment('SUPABASE_URL');
      await http
          .post(
            Uri.parse('$base/functions/v1/send-security-alert'),
            headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
            body: jsonEncode({'event': event, 'deviceLabel': deviceLabel, 'location': location, 'ip': ip}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Best-effort — see doc comment above.
    }
  }

  Future<void> _claimThisDevice(String uid) async {
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    final ip = await _realIp();
    await _sessionRef(uid).set({
      'activeDeviceId': deviceId,
      'activeDeviceLabel': label,
      'activeLocation': location,
      'activeIp': ip,
      'activeSince': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _historyRef(uid).add({
      'event': 'login',
      'deviceId': deviceId,
      'deviceLabel': label,
      'location': location,
      'ip': ip,
      'timestamp': FieldValue.serverTimestamp(),
    });
    unawaited(_sendSecurityAlert('login', label, location, ip));
  }

  /// Records that the account's password was changed — shown in the
  /// Account Security history list. Called from AuthService.updatePassword.
  Future<void> logPasswordChanged(String uid) async {
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    final ip = await _realIp();
    await _historyRef(uid).add({
      'event': 'password_changed',
      'deviceId': deviceId,
      'deviceLabel': label,
      'location': location,
      'ip': ip,
      'timestamp': FieldValue.serverTimestamp(),
    });
    unawaited(_sendSecurityAlert('password_changed', label, location, ip));
  }

  /// Starts watching for "a different device just claimed this account."
  /// Call once per sign-in, including on a cold start with an
  /// already-persisted session (see main.dart) — NOT on every
  /// authStateChanges tick, since re-running claimThisDevice() there would
  /// let a stale, reopened device silently steal the active slot back from
  /// a legitimately newer login. [onSupersededByAnotherDevice] fires when
  /// THIS device has just been replaced, so the caller can force a
  /// sign-out with an explanatory message.
  void watchForRemoteLogout(String uid, void Function() onSupersededByAnotherDevice) {
    _watchSub?.cancel();
    _watchSub = _sessionRef(uid).snapshots().listen((_) async {
      if (isClaimPending) return; // see isClaimPending's doc comment above
      // BUGFIX: deliberately ignore the snapshot's own payload and always
      // re-read fresh below, once any of THIS device's own in-flight
      // claimThisDevice() write has finished. Trusting the delivered
      // snapshot directly was the bug — see [_lastClaim]'s doc comment for
      // exactly why that read as "signed in elsewhere" on every fresh
      // login. Awaiting a null/already-finished future is an instant
      // no-op, so this changes nothing for the genuine "someone else
      // really did just log in elsewhere" case.
      if (_lastClaim != null) await _lastClaim;
      final data = (await _sessionRef(uid).get()).data();
      final activeDeviceId = data?['activeDeviceId'] as String?;
      if (activeDeviceId == null) return; // no claim recorded yet - nothing to compare against
      final myId = await _localDeviceId();
      if (activeDeviceId != myId) {
        onSupersededByAnotherDevice();
      }
    });
  }

  void stopWatching() {
    _watchSub?.cancel();
    _watchSub = null;
  }

  /// [after] is normally the account's `historyClearedAt` timestamp (see
  /// [clearHistoryView]) — pass it to hide everything at or before that
  /// point. The underlying documents are never actually removed (see this
  /// class's own header comment, and firestore.rules' history block: it's
  /// append-only by design).
  Stream<QuerySnapshot<Map<String, dynamic>>> historyStream(String uid, {DateTime? after}) {
    Query<Map<String, dynamic>> query = _historyRef(uid).orderBy('timestamp', descending: true).limit(50);
    if (after != null) {
      query = _historyRef(uid)
          .where('timestamp', isGreaterThan: Timestamp.fromDate(after))
          .orderBy('timestamp', descending: true)
          .limit(50);
    }
    return query.snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> sessionStream(String uid) => _sessionRef(uid).snapshots();

  /// "Clear activity" on the Account Security screen. Doesn't delete the
  /// underlying history documents — firestore.rules makes that collection
  /// append-only on purpose, so an attacker who got hold of the account
  /// couldn't erase evidence of their own login. This just stamps a
  /// cutoff time on the (owner-only) session doc; [historyStream]'s
  /// `after` param uses it to hide anything older, from THIS device's
  /// point of view, without touching the underlying record.
  Future<void> clearHistoryView(String uid) async {
    await _sessionRef(uid).set({'historyClearedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------
  // New-login accept/deny flow (opt-in, default OFF)
  // ---------------------------------------------------------------------
  //
  // With the toggle OFF (the default, and the only behavior that existed
  // before this feature), logging in works exactly as above: the new
  // device calls [claimThisDevice] immediately and the old one gets
  // signed out next time its listener fires.
  //
  // With the toggle ON, a new login does NOT get to call
  // [claimThisDevice] right away. Instead: it creates a doc here with
  // status 'pending', the currently-active device is notified (a live
  // Firestore listener while it's in the foreground — see main.dart —
  // AND a push notification for when it isn't, reusing the exact same
  // Database-Webhook + Edge-Function + FCM pattern send-push already uses
  // for message notifications, just pointed at a new
  // send-login-approval-push function), and the new device waits (60
  // seconds, client-side) for that other device to accept or deny it.
  // Only on acceptance does the new login proceed to [claimThisDevice].
  //
  // Honest limit on what this actually protects against: a deviceId here
  // is a self-generated UUID this app stores in secure storage on first
  // run (see [_localDeviceId]) — it is NOT a cryptographically attested
  // hardware identity, the same trust level [claimThisDevice]'s
  // activeDeviceId already relies on elsewhere in this file. This feature
  // stops an opportunistic or accidental new sign-in (someone else with
  // your password, or you signing in on a device you don't recognize) —
  // it is not a defense against someone with the technical means to talk
  // to Firestore directly instead of through this app.

  Future<bool> isLoginApprovalRequired(String uid) async {
    final data = (await _sessionRef(uid).get()).data();
    return (data?['requireLoginApproval'] as bool?) ?? false;
  }

  Future<void> setRequireLoginApproval(String uid, bool required) =>
      _sessionRef(uid).set({'requireLoginApproval': required}, SetOptions(merge: true));

  /// BUGFIX: [isLoginApprovalRequired] alone gated purely on the toggle,
  /// with no regard for whether there's actually anyone around to answer
  /// the request. That produced a real lock-out: delete the app and
  /// reinstall (a brand-new deviceId, since secure storage is wiped) and
  /// the ONLY device that could ever have approved it is gone for good —
  /// the new login creates a pending request nobody can ever respond to,
  /// every attempt just times out after 60 seconds, forever.
  ///
  /// This is what LoginScreen now calls instead. It keeps the toggle
  /// check, but only actually requires approval if the account's active
  /// device looks genuinely, currently online — reusing the same
  /// self-owned presence doc PresenceService already heartbeats every
  /// ~45s while foregrounded (users/{uid}/private/presence). That matches
  /// what was actually asked for: approval when logging in "while
  /// actively logged in somewhere else," not approval forever because
  /// Firestore still remembers a device that no longer exists.
  ///
  /// Honest limitation: presence is best-effort (see PresenceService's
  /// own doc comment — it can't detect a hard kill or lost network the
  /// way a Realtime Database onDisconnect() could). A device that dies
  /// without a clean pause can look "online" for up to one heartbeat
  /// interval after it's actually gone. That's the safer direction to be
  /// wrong in: it occasionally still asks for approval when it strictly
  /// didn't need to, rather than ever silently skipping a check that
  /// should have fired.
  Future<bool> shouldRequireApprovalForNewLogin(String uid) async {
    if (!await isLoginApprovalRequired(uid)) return false;
    try {
      final presence = await _db.collection('users').doc(uid).collection('private').doc('presence').get();
      final data = presence.data();
      if (data == null) return false; // never seen online - nothing to protect against
      final online = data['online'] as bool? ?? false;
      final lastSeen = data['lastSeen'] as Timestamp?;
      if (!online || lastSeen == null) return false;
      final age = DateTime.now().difference(lastSeen.toDate());
      return age < const Duration(minutes: 3); // heartbeat interval is 45s, generous buffer for lag
    } catch (_) {
      // Best-effort — if presence can't be read for any reason, don't let
      // that lock the person out of their own account. Falling through to
      // "approval not required" here just means this one login proceeds
      // like the toggle was off; it does NOT disable the toggle itself.
      return false;
    }
  }

  /// Called by the NEW device once it's verified the account's password
  /// but before it's allowed to claim itself as active. Writes the
  /// pending request, then best-effort pings Supabase to trigger a push
  /// to the OLD device — a failure there just means no push (the old
  /// device's live listener, if it's foregrounded, still works fine).
  Future<String> createLoginApprovalRequest(String uid) async {
    final requestId = const Uuid().v4();
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    final ip = await _realIp();

    await _approvalsRef(uid).doc(requestId).set({
      'status': 'pending',
      'requestingDeviceId': deviceId,
      'requestingDeviceLabel': label,
      'requestingLocation': location,
      'requestingIp': ip,
      'createdAt': FieldValue.serverTimestamp(),
    });

    try {
      await Supabase.instance.client.from('login_approval_requests').insert({
        'uid': uid,
        'request_id': requestId,
        'device_label': label,
        'location': location,
      });
    } catch (_) {
      // Best-effort — see the doc comment above.
    }

    return requestId;
  }

  /// The NEW device watches this while its "waiting for approval" dialog
  /// is up (see LoginScreen) — emits 'pending', then eventually 'accepted'
  /// or 'denied' once the OLD device responds.
  Stream<String> watchApprovalStatus(String uid, String requestId) => _approvalsRef(uid)
      .doc(requestId)
      .snapshots()
      .map((snap) => (snap.data()?['status'] as String?) ?? 'pending');

  /// Called by the NEW device if the person cancels the wait, or the
  /// 60-second client-side timeout elapses. A no-op if the OLD device
  /// already accepted/denied it in the meantime — this only ever moves a
  /// request OUT of 'pending', never overwrites an existing decision.
  Future<void> expireLoginApprovalRequest(String uid, String requestId) async {
    final ref = _approvalsRef(uid).doc(requestId);
    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if ((snap.data()?['status'] as String?) == 'pending') {
          tx.update(ref, {'status': 'expired'});
        }
      });
    } catch (_) {}
  }

  /// The OLD/active device watches this while foregrounded (see
  /// main.dart) to pop up an in-app Accept/Deny screen the instant a new
  /// login requests approval, without waiting on a push at all. Only ever
  /// the single latest still-pending request — normal use never has more
  /// than one outstanding at a time.
  /// BUGFIX: this used to add `.orderBy('createdAt', descending: true)` on
  /// top of the `.where('status', ...)` filter — combining an equality
  /// filter with an orderBy on a DIFFERENT field requires a Firestore
  /// composite index that was never created (nowhere in this repo asks
  /// you to deploy one). Without it, this query doesn't just return
  /// fewer results — it fails outright (FAILED_PRECONDITION), and since
  /// nothing here was listening for stream errors, that failure was
  /// silently swallowed: the OLD/active device's live "someone wants to
  /// log in" screen never appeared, full stop, no error visible anywhere.
  /// Dropping the orderBy avoids needing that index at all — in normal
  /// use there's only ever one pending request at a time anyway, so
  /// which one `.limit(1)` happens to return doesn't meaningfully matter.
  Stream<Map<String, dynamic>?> watchPendingApprovalRequest(String uid) => _approvalsRef(uid)
      .where('status', isEqualTo: 'pending')
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isEmpty ? null : {'requestId': snap.docs.first.id, ...snap.docs.first.data()});

  /// Called from the OLD/active device — either the in-app dialog
  /// (foreground) or LoginApprovalScreen (opened from a tapped push).
  /// firestore.rules requires [respondingDeviceId] to match the session
  /// doc's current activeDeviceId, which only the actually-active device
  /// can honestly supply (see this section's doc comment for the honest
  /// limit on that guarantee).
  Future<void> respondToLoginApproval({
    required String uid,
    required String requestId,
    required bool approve,
  }) async {
    final deviceId = await _localDeviceId();
    await _approvalsRef(uid).doc(requestId).update({
      'status': approve ? 'accepted' : 'denied',
      'respondingDeviceId': deviceId,
    });
  }
}
