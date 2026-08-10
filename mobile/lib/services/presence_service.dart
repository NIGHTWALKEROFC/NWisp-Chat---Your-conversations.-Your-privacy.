import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Tracks whether the current user appears "online" to others.
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

  static Future<void> goOnline() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({
      'online': true,
      'lastSeen': FieldValue.serverTimestamp(),
    });
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) {
      _db.collection('users').doc(uid).update({'lastSeen': FieldValue.serverTimestamp()});
    });
  }

  static Future<void> goOffline() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({
      'online': false,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchUser(String uid) {
    return _db.collection('users').doc(uid).snapshots();
  }
}
