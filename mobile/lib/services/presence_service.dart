import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Tracks whether the current user appears "online" to others.
///
/// Presence now lives at users/{uid}/private/presence instead of directly
/// on users/{uid} — see firestore.rules. Reads of another person's presence
/// doc are enforced server-side (only allowed when they have last-seen
/// sharing on and haven't blocked you), so a denied read shows up as a
/// stream error rather than just an empty/default doc — callers of
/// [watchUser] should handle that (see ChatDetailScreen).
///
/// NOTE — honest limitation: this is a best-effort presence system built on
/// Firestore. It marks the user online when the app is in the foreground and
/// offline when it's paused/closed normally. It CANNOT detect a hard kill,
/// crash, or lost network connection the way Firebase Realtime Database's
/// onDisconnect() can — that needs the Realtime Database product added to
/// the project, which is a bigger follow-up if reliable "last seen" matters
/// to you.
class PresenceService {
  static final _db = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;
  static Timer? _heartbeat;

  static DocumentReference<Map<String, dynamic>> _presenceRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('presence');

  static Future<void> goOnline() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _presenceRef(uid).set({
      'online': true,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) {
      _presenceRef(uid).set({'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    });
  }

  static Future<void> goOffline() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _presenceRef(uid).set({
      'online': false,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Watches another user's presence doc. Because the read is gated by
  /// server-side rules now, this stream can emit a permission-denied error
  /// instead of data when that user has last-seen sharing off or has
  /// blocked you — callers should treat a stream error the same as
  /// "presence unknown" and just hide the row, not crash.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchUser(String uid) {
    return _presenceRef(uid).snapshots();
  }
}
