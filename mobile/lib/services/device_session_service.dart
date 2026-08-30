import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
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

  // BUGFIX: [watchForRemoteLogout] used to judge its very first Firestore
  // snapshot as-is. That snapshot can easily arrive BEFORE this device's
  // own [claimThisDevice] write has actually landed — claimThisDevice does
  // a device-info lookup, a network geolocation call (up to 5s), and two
  // Firestore writes before it's done, while main.dart's authStateChanges
  // listener calls watchForRemoteLogout almost immediately after sign-in.
  // The result: the listener's first snapshot still reflected whatever was
  // in Firestore from BEFORE this login (which never matches this
  // device), reading as "signed in elsewhere" and signing the person
  // straight back out of the login they just completed — every time.
  // [_lastClaim] lets [watchForRemoteLogout] wait for any of THIS
  // instance's own in-flight claims to finish, then re-read fresh data,
  // before ever judging a mismatch as a real takeover.
  Future<void>? _lastClaim;

  DocumentReference<Map<String, dynamic>> _sessionRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('session');

  CollectionReference<Map<String, dynamic>> _historyRef(String uid) =>
      _sessionRef(uid).collection('history');

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

  Future<void> _claimThisDevice(String uid) async {
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    await _sessionRef(uid).set({
      'activeDeviceId': deviceId,
      'activeDeviceLabel': label,
      'activeLocation': location,
      'activeSince': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _historyRef(uid).add({
      'event': 'login',
      'deviceId': deviceId,
      'deviceLabel': label,
      'location': location,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Records that the account's password was changed — shown in the
  /// Account Security history list. Called from AuthService.updatePassword.
  Future<void> logPasswordChanged(String uid) async {
    final deviceId = await _localDeviceId();
    final label = await _realDeviceLabel();
    final location = await _locationLabel();
    await _historyRef(uid).add({
      'event': 'password_changed',
      'deviceId': deviceId,
      'deviceLabel': label,
      'location': location,
      'timestamp': FieldValue.serverTimestamp(),
    });
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
}
