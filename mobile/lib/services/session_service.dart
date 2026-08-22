import 'package:cloud_firestore/cloud_firestore.dart';
import 'crypto_service.dart';
import 'local_message_store.dart';
import 'pin_service.dart';
import 'secure_storage_service.dart';
import 'signal_session_service.dart';

/// Makes sure this device's local, per-account state (the on-device
/// message store, pinned messages, the Signal Protocol identity/session
/// store) belongs to whoever is CURRENTLY signed in — and never to
/// whoever was signed in before them on this same device.
///
/// Call this once for every sign-in/sign-up (AuthService) and once per app
/// cold start with an already-persisted session (main.dart). It's safe to
/// call more than once in a row for the same uid — later calls are cheap
/// no-ops once the account already matches.
class SessionService {
  static String? _preparingUid;
  static Future<void>? _preparingFuture;

  static Future<void> prepareForUser(String uid) {
    if (_preparingUid == uid && _preparingFuture != null) return _preparingFuture!;
    _preparingUid = uid;
    final future = _prepare(uid);
    _preparingFuture = future;
    return future;
  }

  static Future<void> _prepare(String uid) async {
    final activeUid = await SecureStorageService.getActiveUid();
    final switchedAccount = activeUid != null && activeUid != uid;

    if (switchedAccount) {
      // A different account is signing in on this device. Wipe every bit
      // of the previous account's local state first — the on-device
      // message database, pinned-message ids, and the Signal Protocol
      // store (identity/sessions/prekeys) — so it's never visible to, or
      // reused by, the new one. Without this, a second account signing in
      // on the same device would silently inherit the first account's
      // keys and see the first account's messages.
      await SecureStorageService.clearAll();
      CryptoService.clearInMemoryKeys();
      await LocalMessageStore.resetForNewUser();
      await PinService.clearAll();
      await SignalSessionService.instance.wipe();
    }

    await SecureStorageService.setActiveUid(uid);
    SignalSessionService.setCurrentUid(uid);
    await CryptoService.ensureLocalStorageKey();
    await LocalMessageStore.init();
    // Generates (once) or verifies this account's Double Ratchet identity
    // and prekeys, and republishes/replenishes the public prekey bundle
    // other people need to start a session with this account.
    await SignalSessionService.instance.install();

    await _ensurePrivateDocs(uid);
  }

  /// One-time migration for accounts created before private profile/presence
  /// docs existed: pulls blockedUsers/messageTtlHours/readReceiptsEnabled/
  /// lastSeenVisible/fcmTokens/online/lastSeen off the old flat `users/{uid}`
  /// doc (where any signed-in user could previously read them), copies them
  /// into the new owner-only `private/profile` + `private/presence` docs,
  /// then deletes them from the public doc so the leak is actually closed —
  /// not just avoided for new writes. Cheap no-op for every later call once
  /// the private docs already exist.
  static Future<void> _ensurePrivateDocs(String uid) async {
    final db = FirebaseFirestore.instance;
    final userRef = db.collection('users').doc(uid);
    final profileRef = userRef.collection('private').doc('profile');
    final presenceRef = userRef.collection('private').doc('presence');

    final profileSnap = await profileRef.get();
    if (profileSnap.exists) return; // already migrated / already a new-style account

    final oldSnap = await userRef.get();
    final old = oldSnap.data() ?? {};

    final batch = db.batch();
    batch.set(profileRef, {
      'emailVisible': old['emailVisible'] ?? false,
      'lastSeenVisible': old['lastSeenVisible'] ?? true,
      'readReceiptsEnabled': old['readReceiptsEnabled'] ?? true,
      'blockedUsers': old['blockedUsers'] ?? <String>[],
      'messageTtlHours': old['messageTtlHours'] ?? 0, // never, unless they already had a value set
      'fcmTokens': old['fcmTokens'] ?? <String>[],
      'lastLoginAt': old['lastLoginAt'] ?? FieldValue.serverTimestamp(),
    });
    batch.set(presenceRef, {
      'online': old['online'] ?? false,
      'lastSeen': old['lastSeen'] ?? FieldValue.serverTimestamp(),
    });
    // Strip the now-migrated fields off the public doc so they stop being
    // world-readable to every other signed-in user.
    batch.update(userRef, {
      'emailVisible': FieldValue.delete(),
      'lastSeenVisible': FieldValue.delete(),
      'readReceiptsEnabled': FieldValue.delete(),
      'blockedUsers': FieldValue.delete(),
      'messageTtlHours': FieldValue.delete(),
      'fcmTokens': FieldValue.delete(),
      'lastLoginAt': FieldValue.delete(),
      'online': FieldValue.delete(),
      'lastSeen': FieldValue.delete(),
    });
    // Backfill the blocks/{blockerUid}_{blockedUid} lookup docs (see
    // firestore.rules + ModerationService) so any blocks made before this
    // migration keep being enforced server-side on send, not just locally.
    final oldBlocked = List<String>.from(old['blockedUsers'] ?? []);
    for (final blockedUid in oldBlocked) {
      batch.set(db.collection('blocks').doc('${uid}_$blockedUid'), {
        'blockerUid': uid,
        'blockedUid': blockedUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
}
