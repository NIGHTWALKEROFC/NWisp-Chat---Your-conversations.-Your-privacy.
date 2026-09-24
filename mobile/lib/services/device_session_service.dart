import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'secure_storage_service.dart';

/// What [DeviceSessionService.createLoginApprovalRequest] hands back: the
/// request's id, and the 2-digit number the NEW phone must show on screen.
///
/// Feature: number matching. The old phone shows three numbers and the person
/// has to tap the one that's on the new phone's screen. Somebody who is
/// tricked into (or just reflexively taps) "Accept" for a login they didn't
/// start can't get it right — they aren't looking at the new phone — so a
/// wrong pick DENIES the login instead of approving it.
class LoginApprovalHandle {
  final String requestId;
  final int matchNumber;
  const LoginApprovalHandle({required this.requestId, required this.matchNumber});
}

/// Thrown by [DeviceSessionService.respondToLoginApproval] when the request
/// is no longer waiting for an answer (already accepted/denied, or it
/// expired) — so a double-tap, or two screens open for the same request, can
/// never answer it twice.
class LoginApprovalAlreadyHandled implements Exception {
  const LoginApprovalAlreadyHandled();
  @override
  String toString() => 'This login request has already been handled or has expired.';
}

/// Feature: multiple devices (off by default — see this file's "Multiple
/// devices" section below). Thrown by [claimThisDevice] when multi-device
/// is ON for this account and it's already at its own chosen device limit;
/// the person is still fully signed in to Firebase Auth at this point (the
/// password already checked out), just not yet claimed as an active
/// device — so the app can show them their current device list and let
/// them revoke one to make room, right there, instead of failing the
/// login outright.
class DeviceLimitReachedException implements Exception {
  final int limit;
  const DeviceLimitReachedException(this.limit);
  @override
  String toString() => "You've reached your device limit ($limit). Remove a device to add this one.";
}

/// One row of [DeviceSessionService.devicesStream] — a device that is
/// currently allowed to be signed in to the account, under Multiple
/// devices.
class LinkedDevice {
  final String deviceId;
  final String label;
  final String? location;
  final DateTime? since;
  final DateTime? lastActiveAt;
  final bool isPrimary;
  final bool isThisDevice;
  const LinkedDevice({
    required this.deviceId,
    required this.label,
    required this.location,
    required this.since,
    required this.lastActiveAt,
    required this.isPrimary,
    required this.isThisDevice,
  });
}

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
  // BUGFIX (login approval — "several Done screens" / "requests when nobody
  // is logging in"): approval requests reach the active phone from THREE
  // places (the live Firestore listener, a notification tap, and the app
  // being opened from a notification), and nothing stopped the same request
  // being put on screen by more than one of them — so accepting it once
  // left several "Login approved / Done" screens stacked up. Every path now
  // has to claim the request id here first; only the first one gets to show
  // it, and the screen releases it again when it closes.
  final Set<String> _presentedApprovals = {};

  /// Returns true if THIS caller may put [requestId] on screen (nobody else
  /// has). Call [unmarkApprovalPresented] when that screen closes.
  bool tryMarkApprovalPresented(String requestId) => _presentedApprovals.add(requestId);
  void unmarkApprovalPresented(String requestId) => _presentedApprovals.remove(requestId);

  /// A request older than this is dead: the phone that made it waits at most
  /// 60 seconds, so anything past a few minutes was abandoned (app killed,
  /// network lost, uninstalled). It must never be shown to anyone.
  static const Duration approvalFreshFor = Duration(minutes: 3);

  bool isApprovalFresh(Map<String, dynamic> data) {
    final ts = data['createdAt'];
    if (ts is! Timestamp) return true; // server time not stamped yet => just created
    return DateTime.now().difference(ts.toDate()) < approvalFreshFor;
  }

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

  /// Feature: multiple devices. Each currently-allowed device gets one doc
  /// here (subcollection of the same owner-only session doc, so it shares
  /// its access rule). This is separate from the legacy single
  /// `activeDeviceId` field on the session doc itself, which is left
  /// completely alone and keeps working exactly as before for every
  /// account that never turns this on.
  CollectionReference<Map<String, dynamic>> _devicesRef(String uid) =>
      _sessionRef(uid).collection('devices');

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

  // -----------------------------------------------------------------------
  // Multiple devices (off by default)
  // -----------------------------------------------------------------------
  //
  // OFF (the default, and the only behavior that existed before this
  // feature): completely unchanged — [claimThisDevice] below still goes
  // straight to [_claimThisDevice], the single-active-device path, exactly
  // as it always has. No new reads, no new writes, no behavior change at
  // all for an account that never touches this setting.
  //
  // ON: instead of evicting whatever device was active, this device is
  // added to a small list of currently-allowed devices (up to the person's
  // own chosen limit, 1-5, default 3) at `.../session/devices/{deviceId}`.
  // Every device on that list can sign in to the ACCOUNT — browse
  // contacts, groups, Communities, settings — at the same time.
  //
  // HONEST LIMIT, stated plainly rather than glossed over: this only
  // covers ACCOUNT access, not message encryption. Each 1:1 and group
  // message is end-to-end encrypted using a Signal Protocol identity key
  // pair that is generated ON-DEVICE and never leaves that device (see
  // SignalStore) — that is what makes the encryption real. Because of
  // that, only ONE device — the "primary" device, [primaryDeviceId] below
  // — actually holds the private key other people's apps encrypt new
  // messages against, and only it has any local message history at all.
  // A second signed-in device can manage the account but its chat screens
  // stay blocked (see requirePrimaryDeviceForChat) rather than pretending
  // to show chats it fundamentally cannot decrypt. "Make this my primary
  // device" (see [makeThisDevicePrimary] + SignalSessionService's matching
  // method) moves messaging here instead — but, exactly like reinstalling
  // the app, it hands this device a brand-new identity key, so every
  // contact's app will show its existing "identity changed" warning and
  // may want to re-verify. That's the honest, correct behavior for a
  // security feature like that, not a bug to hide.

  static const int minDevices = 1;
  static const int maxDevicesLimit = 5;
  static const int defaultMaxDevices = 3;

  Future<bool> isMultiDeviceEnabled(String uid) async {
    final data = (await _sessionRef(uid).get()).data();
    return (data?['multiDeviceEnabled'] as bool?) ?? false;
  }

  Future<int> getMaxDevices(String uid) async {
    final data = (await _sessionRef(uid).get()).data();
    final v = (data?['maxDevices'] as num?)?.toInt() ?? defaultMaxDevices;
    return v.clamp(minDevices, maxDevicesLimit);
  }

  /// Turning this ON does not touch anyone's device list by itself — the
  /// device that's already active simply becomes the first entry (and the
  /// primary) the next time it claims itself, which happens naturally
  /// on this device's own next app open/foreground (see main.dart).
  /// Turning it OFF does not forcibly sign anyone else out either — it just
  /// means the NEXT login anywhere goes back to the original
  /// one-device-at-a-time behavior (evicting whichever device that login
  /// finds active), same as if the feature had never existed.
  Future<void> setMultiDeviceEnabled(String uid, bool enabled) =>
      _sessionRef(uid).set({'multiDeviceEnabled': enabled}, SetOptions(merge: true));

  Future<void> setMaxDevices(String uid, int max) =>
      _sessionRef(uid).set({'maxDevices': max.clamp(minDevices, maxDevicesLimit)}, SetOptions(merge: true));

  Future<bool> isPrimaryDevice(String uid) async {
    final data = (await _sessionRef(uid).get()).data();
    final primary = data?['primaryDeviceId'] as String?;
    if (primary == null) return true; // nothing chosen yet - don't block a fresh single-device account
    return primary == await _localDeviceId();
  }

  /// Moves the "primary" (messaging-capable) role to THIS device. Only
  /// changes the pointer — actually generating this device a fresh Signal
  /// identity and republishing its bundle is done by the caller via
  /// SignalSessionService.resetIdentityOnThisDevice, since that's a much
  /// more consequential, slower operation this method shouldn't hide
  /// inside a plain-sounding setter.
  Future<void> makeThisDevicePrimary(String uid) async {
    final deviceId = await _localDeviceId();
    await _sessionRef(uid).set({'primaryDeviceId': deviceId}, SetOptions(merge: true));
  }

  Stream<List<LinkedDevice>> devicesStream(String uid) {
    return _sessionRef(uid).snapshots().asyncMap((sessionSnap) async {
      final primary = sessionSnap.data()?['primaryDeviceId'] as String?;
      final myId = await _localDeviceId();
      final docs = await _devicesRef(uid).get();
      final list = docs.docs.map((d) {
        final data = d.data();
        return LinkedDevice(
          deviceId: d.id,
          label: (data['deviceLabel'] as String?) ?? 'A device',
          location: data['location'] as String?,
          since: (data['since'] as Timestamp?)?.toDate(),
          lastActiveAt: (data['lastActiveAt'] as Timestamp?)?.toDate(),
          isPrimary: d.id == primary,
          isThisDevice: d.id == myId,
        );
      }).toList();
      list.sort((a, b) {
        if (a.isThisDevice != b.isThisDevice) return a.isThisDevice ? -1 : 1;
        if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
        return (b.lastActiveAt ?? DateTime(0)).compareTo(a.lastActiveAt ?? DateTime(0));
      });
      return list;
    });
  }

  /// Signs a device out immediately — from ANY of the person's own signed-in
  /// devices, including the one being removed. Refuses to remove the
  /// primary device while others remain, since that would strand every
  /// other device's messaging with nowhere to go; move the primary role
  /// first (see [makeThisDevicePrimary]).
  Future<void> revokeDevice(String uid, String deviceId) async {
    final data = (await _sessionRef(uid).get()).data();
    final primary = data?['primaryDeviceId'] as String?;
    if (deviceId == primary) {
      final remaining = await _devicesRef(uid).get();
      if (remaining.docs.length > 1) {
        throw StateError('Make another device primary before removing this one.');
      }
    }
    await _devicesRef(uid).doc(deviceId).delete();
  }

  /// Watches THIS device's own entry under multi-device — fires
  /// [onRevoked] the moment it's removed (by itself elsewhere, or by
  /// another of the person's own devices). Only meaningful once
  /// multi-device is on and this device has actually claimed itself; a
  /// no-op subscription otherwise. Separate from [watchForRemoteLogout],
  /// which still handles the classic single-device eviction case.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _revocationSub;
  Future<void> watchForRevocation(String uid, void Function() onRevoked) async {
    _revocationSub?.cancel();
    final deviceId = await _localDeviceId();
    _revocationSub = _devicesRef(uid).doc(deviceId).snapshots().listen((snap) {
      if (isClaimPending) return;
      if (!snap.exists) onRevoked();
    });
  }

  void stopWatchingRevocation() {
    _revocationSub?.cancel();
    _revocationSub = null;
  }

  /// The multi-device claim path — see the section doc comment above for
  /// what this does and, just as importantly, what it deliberately does
  /// NOT do (fan out message decryption to every device).
  Future<void> _claimThisDeviceMultiDevice(String uid) async {
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    final ip = await _realIp();
    final maxDevices = await getMaxDevices(uid);

    final existing = await _devicesRef(uid).get();
    final alreadyListed = existing.docs.any((d) => d.id == deviceId);
    if (!alreadyListed && existing.docs.length >= maxDevices) {
      throw DeviceLimitReachedException(maxDevices);
    }

    await _devicesRef(uid).doc(deviceId).set({
      'deviceLabel': label,
      'location': location,
      'ip': ip,
      'since': alreadyListed ? existing.docs.firstWhere((d) => d.id == deviceId).data()['since'] : FieldValue.serverTimestamp(),
      'lastActiveAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // The very first device ever claimed under multi-device becomes
    // primary automatically; every device claimed after that keeps
    // whichever one already holds the role, unless makeThisDevicePrimary
    // is called explicitly.
    final sessionData = (await _sessionRef(uid).get()).data();
    if (sessionData?['primaryDeviceId'] == null) {
      await _sessionRef(uid).set({'primaryDeviceId': deviceId}, SetOptions(merge: true));
    }

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
    if (await isMultiDeviceEnabled(uid)) {
      await _claimThisDeviceMultiDevice(uid);
      return;
    }
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
  /// True only if THIS phone is the account's current active device. Only
  /// the active device is ever allowed to be asked to approve a new login —
  /// a phone that is itself still signing in (or one that was signed out
  /// earlier) must never be shown someone else's approval prompt.
  Future<bool> isThisDeviceActive(String uid) async {
    final data = (await _sessionRef(uid).get()).data();
    final activeDeviceId = data?['activeDeviceId'] as String?;
    if (activeDeviceId == null) return false;
    return activeDeviceId == await _localDeviceId();
  }

  /// Called on a normal sign-out: if this phone is the account's active
  /// device, give that up so the account honestly reads as "nobody is signed
  /// in". If ANOTHER phone already took over, this does nothing (the claim
  /// isn't ours to release).
  Future<void> releaseActiveClaimIfMine(String uid) async {
    final myId = await _localDeviceId();
    final data = (await _sessionRef(uid).get().timeout(const Duration(seconds: 5))).data();
    // Feature: multiple devices — a normal sign-out on one device should
    // only remove THAT device from the list, never the others.
    if (data?['multiDeviceEnabled'] == true) {
      try {
        await _devicesRef(uid).doc(myId).delete().timeout(const Duration(seconds: 5));
      } catch (_) {}
      return;
    }
    if (data?['activeDeviceId'] != myId) return;
    await _sessionRef(uid).update({
      'activeDeviceId': FieldValue.delete(),
      'activeDeviceLabel': FieldValue.delete(),
      'activeLocation': FieldValue.delete(),
    }).timeout(const Duration(seconds: 5));
  }

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
      // Feature: multiple devices — once it's on for this account, being
      // signed in on more than one device at once is the whole point, so
      // the single-active-device eviction check below no longer applies.
      // watchForRevocation (started alongside this, see main.dart) is what
      // signs a device out under multi-device: only ever because that
      // specific device was deliberately removed, never just because
      // another one is also signed in.
      if (await isMultiDeviceEnabled(uid)) return;
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
    stopWatchingRevocation();
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
      // BUGFIX: approval is only meaningful if there is another phone that is
      // actually signed in to answer. If nobody holds the active-device claim
      // (everyone signed out), or the claim is this very phone signing back
      // in, asking for approval just made the person wait 60 seconds for a
      // phone that could never reply — "requests coming even though nobody is
      // logged in".
      final session = (await _sessionRef(uid).get()).data();
      final activeDeviceId = session?['activeDeviceId'] as String?;
      if (activeDeviceId == null) return false;
      if (activeDeviceId == await _localDeviceId()) return false;

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
  Future<LoginApprovalHandle> createLoginApprovalRequest(String uid) async {
    final requestId = const Uuid().v4();
    // 10-99: always two digits, so it's quick to read and to compare.
    final matchNumber = 10 + Random.secure().nextInt(90);
    final deviceId = await _localDeviceId();
    // A fresh attempt supersedes any earlier abandoned one from this phone.
    await _expireMyPendingRequests(uid, deviceId);
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    final ip = await _realIp();

    await _approvalsRef(uid).doc(requestId).set({
      'status': 'pending',
      'requestingDeviceId': deviceId,
      'requestingDeviceLabel': label,
      'requestingLocation': location,
      'requestingIp': ip,
      // The number itself is NOT sent in the push notification (only the
      // device label and location are — see the insert below), so a
      // notification alone never gives the answer away.
      'matchNumber': matchNumber,
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

    return LoginApprovalHandle(requestId: requestId, matchNumber: matchNumber);
  }

  /// The NEW device watches this while its "waiting for approval" dialog
  /// is up (see LoginScreen) — emits 'pending', then eventually 'accepted'
  /// or 'denied' once the OLD device responds.
  Future<void> _expireMyPendingRequests(String uid, String myDeviceId) async {
    try {
      final pending = await _approvalsRef(uid).where('status', isEqualTo: 'pending').get();
      for (final doc in pending.docs) {
        if (doc.data()['requestingDeviceId'] == myDeviceId) {
          await expireLoginApprovalRequest(uid, doc.id);
        }
      }
    } catch (_) {}
  }

  /// One-shot read of a request (used to double-check it's still pending and
  /// fresh before showing it).
  Future<Map<String, dynamic>?> getApprovalRequest(String uid, String requestId) async {
    final snap = await _approvalsRef(uid).doc(requestId).get();
    final data = snap.data();
    return data == null ? null : {'requestId': snap.id, ...data};
  }

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
  /// The newest still-FRESH pending request, or null. Stale ones (abandoned
  /// attempts that were never marked expired) are ignored — before this they
  /// kept coming back as phantom "approve this login?" prompts, including on
  /// a phone that had just been reinstalled. Deliberately still a plain
  /// single-field query (no orderBy/limit) so it needs no composite index.
  Stream<Map<String, dynamic>?> watchPendingApprovalRequest(String uid) =>
      _approvalsRef(uid).where('status', isEqualTo: 'pending').snapshots().map((snap) {
        Map<String, dynamic>? newest;
        DateTime? newestAt;
        for (final doc in snap.docs) {
          final data = doc.data();
          if (!isApprovalFresh(data)) continue;
          final ts = data['createdAt'];
          final at = ts is Timestamp ? ts.toDate() : DateTime.now();
          if (newest == null || at.isAfter(newestAt!)) {
            newest = {'requestId': doc.id, ...data};
            newestAt = at;
          }
        }
        return newest;
      });

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
    final ref = _approvalsRef(uid).doc(requestId);
    // A transaction so it only goes through if the request is STILL waiting:
    // a second tap, a second open screen, or an already-expired request
    // throws [LoginApprovalAlreadyHandled] instead of answering twice.
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists || (snap.data()?['status'] as String?) != 'pending') {
        throw const LoginApprovalAlreadyHandled();
      }
      tx.update(ref, {
        'status': approve ? 'accepted' : 'denied',
        'respondingDeviceId': deviceId,
      });
    });
  }
}
