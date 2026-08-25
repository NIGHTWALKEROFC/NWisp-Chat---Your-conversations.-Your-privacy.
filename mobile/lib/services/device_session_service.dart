import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
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

  /// Call right after a successful sign-in/sign-up (see AuthService). Makes
  /// THIS device the one-and-only active device for the account — any
  /// other device that was previously active gets signed out next time its
  /// listener fires (see [watchForRemoteLogout]), typically within
  /// seconds if it's online, or the next time it's foregrounded otherwise.
  Future<void> claimThisDevice(String uid) async {
    final deviceId = await _localDeviceId();
    final label = _deviceLabel(deviceId);
    await _sessionRef(uid).set({
      'activeDeviceId': deviceId,
      'activeDeviceLabel': label,
      'activeSince': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _historyRef(uid).add({
      'event': 'login',
      'deviceId': deviceId,
      'deviceLabel': label,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Records that the account's password was changed — shown in the
  /// Account Security history list. Called from AuthService.updatePassword.
  Future<void> logPasswordChanged(String uid) async {
    final deviceId = await _localDeviceId();
    await _historyRef(uid).add({
      'event': 'password_changed',
      'deviceId': deviceId,
      'deviceLabel': _deviceLabel(deviceId),
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
    _watchSub = _sessionRef(uid).snapshots().listen((snap) async {
      final activeDeviceId = snap.data()?['activeDeviceId'] as String?;
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
