import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'media_service.dart';

/// blockedUsers now lives at users/{uid}/private/profile (owner-only —
/// see firestore.rules) instead of directly on users/{uid}, which used to
/// let any signed-in user read who you'd blocked.
///
/// Blocking/unblocking now writes to TWO places: your own private profile
/// (for your own "Blocked users" screen + isBlocked() checks) and a small
/// `blocks/{blockerUid}_{blockedUid}` doc, which is the only thing that
/// tells the OTHER person's device "you've been blocked, don't let them
/// send" (see MessageRelayService._checkNotBlocked) — without exposing your
/// whole block list to them or anyone else.
///
/// Fixed list of report/appeal reasons shown on ReportUserScreen — kept
/// here (not in the screen) so anything reading a report's `ruleViolated`
/// value (you, in the Firebase console) has one canonical list to match
/// against.
const List<String> reportableRules = [
  'Harassment or bullying',
  'Spam or scams',
  'Impersonation',
  'Sharing illegal content',
  'Sexual content involving a minor',
  'Violence or threats',
  'Hate speech',
  'Other',
];

class ModerationService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String get _myUid => _auth.currentUser!.uid;

  DocumentReference<Map<String, dynamic>> get _profileRef =>
      _db.collection('users').doc(_myUid).collection('private').doc('profile');

  DocumentReference<Map<String, dynamic>> _blockDocRef(String blockedUid) =>
      _db.collection('blocks').doc('${_myUid}_$blockedUid');

  Future<void> blockUser(String uid) async {
    final batch = _db.batch();
    batch.set(_profileRef, {
      'blockedUsers': FieldValue.arrayUnion([uid]),
    }, SetOptions(merge: true));
    batch.set(_blockDocRef(uid), {
      'blockerUid': _myUid,
      'blockedUid': uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<void> unblockUser(String uid) async {
    final batch = _db.batch();
    batch.set(_profileRef, {
      'blockedUsers': FieldValue.arrayRemove([uid]),
    }, SetOptions(merge: true));
    batch.delete(_blockDocRef(uid));
    await batch.commit();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> myProfileStream() {
    return _profileRef.snapshots();
  }

  Future<bool> isBlocked(String uid) async {
    final doc = await _profileRef.get();
    final blocked = List<String>.from(doc.data()?['blockedUsers'] ?? []);
    return blocked.contains(uid);
  }

  /// Feature: more 1:1 chat security settings — "Hide sender name in
  /// notifications" (see ChatSettingsScreen). Push notification bodies
  /// already never contain message content (there's nothing to leak —
  /// this app never has decrypted content server-side to put in one, see
  /// send-push's own comment on that), but the notification TITLE still
  /// shows the sender's username by default, which is its own real
  /// lock-screen privacy leak for a specific contact someone would
  /// rather keep off their lock screen entirely. `notificationPrivacyPeers`
  /// lives on the SAME owner-only private/profile doc blockedUsers
  /// already does — send-push reads it (using its existing service-role
  /// Firestore access, same as it already reads fcmTokens/mutedBy) to
  /// decide whether to show "New message" instead of the real username
  /// for that one sender.
  Future<void> setNotificationPrivacy(String otherUid, bool hideSenderName) async {
    await _profileRef.set({
      'notificationPrivacyPeers': hideSenderName ? FieldValue.arrayUnion([otherUid]) : FieldValue.arrayRemove([otherUid]),
    }, SetOptions(merge: true));
  }

  Future<bool> isNotificationPrivacyEnabled(String otherUid) async {
    final doc = await _profileRef.get();
    final peers = List<String>.from(doc.data()?['notificationPrivacyPeers'] ?? []);
    return peers.contains(otherUid);
  }

  /// Feature: reporting + admin review + suspension + appeals.
  ///
  /// [ruleViolated] should be one of [reportableRules] (enforced by the
  /// picker on ReportUserScreen, not by this method itself). [proofFile],
  /// if given, is uploaded through the exact same signed-URL pipeline
  /// chat media already uses ([MediaService.uploadFile]) — reusing that
  /// path means no Edge Function changes were needed for this feature at
  /// all, since it already restricts uploads to "your own uid" as the
  /// first path segment, which `report-proof/<your uid>/...` satisfies
  /// just like `avatars/<your uid>.jpg` or `stories/<your uid>/...` do.
  ///
  /// The reporter's own email is attached automatically (from Firebase
  /// Auth, never something they type in) so you — the admin, reading
  /// this in the Firebase console — can email them the outcome later.
  /// It is NEVER shown to the reported user: `reports/{reportId}` has
  /// `allow read: if false` in firestore.rules, so the app itself can't
  /// read reports back at all, only create them; you read them via the
  /// Admin SDK in the console, which bypasses that rule entirely.
  Future<String> reportUser({
    required String reportedUid,
    required String ruleViolated,
    String? details,
    File? proofFile,
  }) async {
    final reportRef = _db.collection('reports').doc();
    String? proofPath;
    if (proofFile != null) {
      final ext = proofFile.path.split('.').last;
      proofPath = await MediaService.uploadFile(
        proofFile,
        'media',
        'report-proof/$_myUid/${reportRef.id}.$ext',
      );
    }
    await reportRef.set({
      'reporterUid': _myUid,
      'reporterEmail': _auth.currentUser?.email,
      'reportedUid': reportedUid,
      'ruleViolated': ruleViolated,
      'details': details,
      'proofPath': proofPath,
      'status': 'pending', // you flip this by hand in the console — see MODERATION_GUIDE.md
      'createdAt': FieldValue.serverTimestamp(),
    });
    return reportRef.id;
  }

  /// Feature: appeals. Same reasoning as [reportUser] for the attached
  /// email and the proof-upload path. [proofFile] is optional — a person
  /// appealing doesn't necessarily have anything to attach, unlike a
  /// reporter who's asked to back up a specific claim.
  Future<String> submitAppeal({
    required String text,
    File? proofFile,
  }) async {
    final appealRef = _db.collection('appeals').doc();
    String? proofPath;
    if (proofFile != null) {
      final ext = proofFile.path.split('.').last;
      proofPath = await MediaService.uploadFile(
        proofFile,
        'media',
        'appeal-proof/$_myUid/${appealRef.id}.$ext',
      );
    }
    await appealRef.set({
      'uid': _myUid,
      'appellantEmail': _auth.currentUser?.email,
      'text': text,
      'proofPath': proofPath,
      'status': 'pending', // you flip this by hand in the console — see MODERATION_GUIDE.md
      'createdAt': FieldValue.serverTimestamp(),
    });
    return appealRef.id;
  }
}
