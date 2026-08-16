import 'package:cloud_firestore/cloud_firestore.dart';
import 'crypto_service.dart';
import 'local_message_store.dart';
import 'message_relay_service.dart';
import 'pin_service.dart';
import 'secure_storage_service.dart';

/// Makes sure this device's local, per-account state (identity keys, the
/// on-device message store, pinned messages, cached peer public keys)
/// belongs to whoever is CURRENTLY signed in — and never to whoever was
/// signed in before them on this same device.
///
/// Call this once for every sign-in/sign-up (AuthService) and once per app
/// cold start with an already-persisted session (main.dart). It's safe to
/// call more than once in a row for the same uid — later calls are cheap
/// no-ops once the account already matches.
class SessionService {
  static String? _preparingUid;
  static Future<String>? _preparingFuture;

  static Future<String> prepareForUser(String uid) {
    if (_preparingUid == uid && _preparingFuture != null) return _preparingFuture!;
    _preparingUid = uid;
    final future = _prepare(uid);
    _preparingFuture = future;
    return future;
  }

  static Future<String> _prepare(String uid) async {
    final activeUid = await SecureStorageService.getActiveUid();
    final switchedAccount = activeUid != null && activeUid != uid;

    if (switchedAccount) {
      // A different account is signing in on this device. Wipe every bit
      // of the previous account's local state first — identity keys, the
      // on-device message database, pinned-message ids, and the in-memory
      // public-key cache — so it's never visible to, or reused by, the new
      // one. Without this, a second account signing in on the same device
      // would silently inherit the first account's keys and see the first
      // account's messages.
      await SecureStorageService.clearAll();
      CryptoService.clearInMemoryKeys();
      await LocalMessageStore.resetForNewUser();
      await PinService.clearAll();
      MessageRelayService.resetPublicKeyCache();
    }

    await SecureStorageService.setActiveUid(uid);
    final publicKey = await CryptoService.ensureIdentityKeyPair();
    await CryptoService.ensureLocalStorageKey();
    await LocalMessageStore.init();

    // Keep Firestore's copy of the public key in sync with whatever this
    // device is actually holding — cheap, and it's exactly what fixes a
    // stale key left over from before an account switch or a reinstall.
    await FirebaseFirestore.instance.collection('users').doc(uid).set(
      {'publicKey': publicKey},
      SetOptions(merge: true),
    );

    return publicKey;
  }
}
