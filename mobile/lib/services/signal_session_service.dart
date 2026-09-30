import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'post_quantum_service.dart';
import 'signal_store.dart';

/// Thrown when [uid] has never published a Signal Protocol key bundle at
/// all — meaning either they haven't opened this version of the app yet
/// (still on an old version without end-to-end encryption support), or
/// they've never signed in on any device. This is distinct from a
/// transient send failure (network blip, a momentarily-exhausted one-time
/// prekey pool): retrying RIGHT NOW would fail again for the exact same
/// reason, since nothing has changed. Callers use this to avoid spamming
/// an actionable "try again" prompt for something an instant retry can't
/// fix — see GroupMessageRelayService's pending-resend queue, which
/// instead waits and retries automatically once the contact's bundle
/// actually shows up.
class ContactNotUpgradedException implements Exception {
  final String uid;
  ContactNotUpgradedException(this.uid);
  @override
  String toString() => "This contact hasn't set up secure messaging yet — ask them to update and reopen the app.";
}

/// High-level Double Ratchet API used by MessageRelayService. Wraps
/// libsignal_protocol_dart's SessionBuilder/SessionCipher plus the
/// Firestore-based prekey bundle publish/fetch that makes X3DH (the
/// handshake that lets you message someone who's offline right now)
/// possible in the first place.
///
/// Replaces the app's previous static-key X25519 scheme: instead of one
/// long-lived shared key per conversation, every message advances a
/// ratchet, so a single leaked key can't decrypt anything sent before or
/// after it (forward secrecy + break-in recovery).
class SignalSessionService {
  SignalSessionService._();
  static final instance = SignalSessionService._();

  final _store = PersistentSignalProtocolStore();
  final _db = FirebaseFirestore.instance;

  static const _oneTimePreKeyBatchSize = 100;
  static const _replenishThreshold = 15;
  static const _deviceId = 1; // single-device for now — see Phase 6 (multi-device)

  DocumentReference<Map<String, dynamic>> _bundleRef(String uid) =>
      _db.collection('users').doc(uid).collection('signal').doc('bundle');

  CollectionReference<Map<String, dynamic>> _oneTimePreKeysRef(String uid) =>
      _bundleRef(uid).collection('oneTimePreKeys');

  SignalProtocolAddress _addressFor(String uid) => SignalProtocolAddress(uid, _deviceId);

  /// Call once per sign-in (see SessionService). Generates this device's
  /// Signal identity + prekeys the first time, or just makes sure they're
  /// loaded otherwise — then republishes/replenishes the public bundle.
  Future<void> install() async {
    await _store.open();
    if (!await _store.hasIdentity()) {
      final identityKeyPair = generateIdentityKeyPair();
      final registrationId = generateRegistrationId(false);
      await _store.saveLocalIdentity(identityKeyPair, registrationId);

      final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
      await _store.storeSignedPreKey(signedPreKey.id, signedPreKey);

      final preKeys = generatePreKeys(0, _oneTimePreKeyBatchSize);
      for (final pk in preKeys) {
        await _store.storePreKey(pk.id, pk);
      }
      await _publishBundle(identityKeyPair, registrationId, signedPreKey, preKeys);
    } else {
      await _replenishIfLow();
    }
    // Feature: post-quantum layer. Creates / rotates and publishes this
    // phone's ML-KEM public key, signed by the identity key. Never throws.
    try {
      await PostQuantumService.instance.ensurePublished(
        uid: _myUidOrThrow(),
        identityKeyPair: await _store.getIdentityKeyPair(),
      );
    } catch (_) {}
  }

  /// Wipes this device's entire Signal identity/session state — used when
  /// a different account signs in on this device (see SessionService).
  Future<void> wipe() async {
    await _store.wipeAll();
    await PostQuantumService.instance.wipe();
  }

  /// Feature: multiple devices — "Make this my primary device" (see
  /// DeviceSessionService.makeThisDevicePrimary, which this is always
  /// called alongside). Generates a brand-new identity key pair for THIS
  /// device and republishes it as the account's bundle, exactly what
  /// [install] would do on a fresh reinstall with no existing identity.
  ///
  /// This is not a lightweight switch: it orphans whatever identity key
  /// this account's contacts currently have pinned for it, so every one of
  /// their apps will show the same "identity changed" warning they'd see
  /// after a reinstall, and existing Double Ratchet sessions with them
  /// have to be re-established from scratch on next contact. That's the
  /// correct, expected behavior for a real key change, not a bug —
  /// silently keeping the old key "working" across two different physical
  /// devices is what would actually be unsafe.
  Future<void> resetIdentityOnThisDevice() async {
    await wipe();
    await install();
  }

  Future<void> _publishBundle(
    IdentityKeyPair identityKeyPair,
    int registrationId,
    SignedPreKeyRecord signedPreKey,
    List<PreKeyRecord> oneTimePreKeys,
  ) async {
    final uid = _myUidOrThrow();
    await _bundleRef(uid).set({
      'registrationId': registrationId,
      'identityKey': bytesToB64(identityKeyPair.getPublicKey().serialize()),
      'signedPreKeyId': signedPreKey.id,
      'signedPreKeyPublic': bytesToB64(signedPreKey.getKeyPair().publicKey.serialize()),
      'signedPreKeySignature': bytesToB64(signedPreKey.signature),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    final batch = _db.batch();
    for (final pk in oneTimePreKeys) {
      batch.set(_oneTimePreKeysRef(uid).doc('${pk.id}'), {
        'id': pk.id,
        'publicKey': bytesToB64(pk.getKeyPair().publicKey.serialize()),
      });
    }
    await batch.commit();
  }

  /// Uploads a fresh batch of one-time prekeys once the count left in
  /// Firestore gets low — otherwise, after enough new people message this
  /// user for the first time, the pool runs out and NEW contacts can no
  /// longer establish a session with them (existing sessions keep working
  /// fine either way, since they don't need one-time prekeys again).
  Future<void> _replenishIfLow() async {
    final uid = _myUidOrThrow();
    final existing = await _oneTimePreKeysRef(uid).count().get();
    final remaining = existing.count ?? 0;
    if (remaining >= _replenishThreshold) return;

    final maxIdRow = await _oneTimePreKeysRef(uid).orderBy('id', descending: true).limit(1).get();
    final startId = maxIdRow.docs.isEmpty ? 0 : (maxIdRow.docs.first.data()['id'] as int) + 1;
    final newPreKeys = generatePreKeys(startId, _oneTimePreKeyBatchSize);
    final batch = _db.batch();
    for (final pk in newPreKeys) {
      await _store.storePreKey(pk.id, pk);
      batch.set(_oneTimePreKeysRef(uid).doc('${pk.id}'), {
        'id': pk.id,
        'publicKey': bytesToB64(pk.getKeyPair().publicKey.serialize()),
      });
    }
    await batch.commit();
  }

  /// Claims (and removes) exactly one of a contact's uploaded one-time
  /// prekeys. Firestore transactions can't run an arbitrary query, so this
  /// does the standard "peek a candidate outside the transaction, then
  /// confirm-and-delete it inside one" pattern, retrying if another sender
  /// won the race for the same prekey a moment earlier.
  Future<Map<String, dynamic>?> _claimOneTimePreKey(String uid) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final candidates = await _oneTimePreKeysRef(uid).limit(1).get();
      if (candidates.docs.isEmpty) return null; // pool exhausted - session will proceed without one (still safe, just no extra forward-secrecy round)
      final ref = candidates.docs.first.reference;
      try {
        return await _db.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (!snap.exists) return null; // someone else claimed it a moment ago - caller retries
          tx.delete(ref);
          return snap.data();
        });
      } catch (_) {
        continue; // transient conflict - try again with a fresh candidate
      }
    }
    return null;
  }

  Future<void> _ensureSession(String uid) async {
    final address = _addressFor(uid);
    if (await _store.containsSession(address)) return;

    final bundleDoc = await _bundleRef(uid).get();
    final bundleData = bundleDoc.data();
    if (bundleData == null) {
      throw ContactNotUpgradedException(uid);
    }

    final oneTimePreKey = await _claimOneTimePreKey(uid);
    if (oneTimePreKey == null) {
      // The confirmed example for this package always supplies a real
      // one-time prekey in PreKeyBundle - omitting one isn't a path this
      // integration has verified, so rather than guess at an unconfirmed
      // "no prekey" bundle shape, surface a clear, retryable error. In
      // practice this should be rare: replenishment kicks in well before
      // the pool empties (see _replenishIfLow), so it would only happen if
      // an unusually large burst of new contacts messaged this person for
      // the first time all before their next app open.
      throw Exception(
        "Couldn't start a secure session with this contact right now — please try again in a moment.",
      );
    }

    final identityKeyBytes = b64ToBytes(bundleData['identityKey'] as String);
    final bundle = PreKeyBundle(
      bundleData['registrationId'] as int,
      _deviceId,
      oneTimePreKey['id'] as int,
      Curve.decodePoint(b64ToBytes(oneTimePreKey['publicKey'] as String), 0),
      bundleData['signedPreKeyId'] as int,
      Curve.decodePoint(b64ToBytes(bundleData['signedPreKeyPublic'] as String), 0),
      b64ToBytes(bundleData['signedPreKeySignature'] as String),
      IdentityKey.fromBytes(identityKeyBytes, 0),
    );

    // Check-before-trust: don't let processPreKeyBundle silently pin a
    // changed identity key. If this contact's key has changed since we
    // last established a session with them, surface that distinctly so
    // the UI can ask before proceeding (see IdentityChangedException).
    if (await _store.isIdentityChanged(address, bundle.getIdentityKey())) {
      throw IdentityChangedException(uid);
    }

    final sessionBuilder = SessionBuilder(_store, _store, _store, _store, address);
    await sessionBuilder.processPreKeyBundle(bundle);
  }

  /// Call after the person has explicitly confirmed they still want to
  /// message this contact despite a changed identity key (see
  /// IdentityChangedException) — re-pins the new key as trusted and
  /// retries session establishment.
  Future<void> acceptChangedIdentityAndRetry(String uid) async {
    final address = _addressFor(uid);
    final bundleDoc = await _bundleRef(uid).get();
    final bundleData = bundleDoc.data();
    if (bundleData == null) throw Exception('No key bundle found for that contact.');
    final identityKey = IdentityKey.fromBytes(b64ToBytes(bundleData['identityKey'] as String), 0);
    await _store.saveIdentity(address, identityKey);
    await _store.deleteSession(address); // force a clean handshake under the newly-trusted key
    await _ensureSession(uid);
  }

  /// Encrypts [plaintext] for [uid], establishing a session first via X3DH
  /// if this is the first message ever sent to them. Returns
  /// (ciphertextB64, typeMarker) — typeMarker is '3' for the first message
  /// in a session (carries the handshake data) or '1' for every message
  /// after (pure ratchet-advanced ciphertext), matching Signal's own
  /// PreKeySignalMessage vs SignalMessage distinction.
  ///
  /// Feature: post-quantum layer. When the contact has published an ML-KEM
  /// key, the Double Ratchet ciphertext is sealed once more with a key from
  /// an ML-KEM-768 exchange (see PostQuantumService) and the marker becomes
  /// 'P3' / 'P1'. Contacts on an older app get the classical marker as before
  /// — unless strict mode (or [requirePq]) is on, which blocks that send.
  Future<(String, String)> encryptForPeer(String uid, String plaintext, {bool requirePq = false}) async {
    await _ensureSession(uid);
    final cipher = SessionCipher(_store, _store, _store, _store, _addressFor(uid));
    final ciphertext = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
    final typeMarker = ciphertext.getType() == CiphertextMessage.prekeyType ? '3' : '1';
    final inner = ciphertext.serialize();
    final peerIdentity = await peerIdentityPublicKeyBytes(uid);
    if (peerIdentity != null) {
      final wrapped = await PostQuantumService.instance.wrapForPeer(
        myUid: _myUidOrThrow(),
        peerUid: uid,
        peerIdentityKey: peerIdentity,
        inner: inner,
        requirePq: requirePq,
      );
      if (wrapped != null) return (bytesToB64(wrapped), 'P$typeMarker');
    }
    return (bytesToB64(inner), typeMarker);
  }

  /// Decrypts a message from [uid]. [typeMarker] is whatever
  /// [encryptForPeer] tagged it with on the sending side (see above).
  Future<String> decryptFromPeer(String uid, String ciphertextB64, String typeMarker) async {
    // Feature: post-quantum layer — 'P3' / 'P1' means an ML-KEM envelope
    // wraps the normal Double Ratchet message. Open it, then carry on with
    // the ordinary '3' / '1' path below.
    if (typeMarker.startsWith('P')) {
      final inner = await PostQuantumService.instance.unwrapFromPeer(
        myUid: _myUidOrThrow(),
        peerUid: uid,
        envelope: b64ToBytes(ciphertextB64),
      );
      return _decryptSignal(uid, bytesToB64(inner), typeMarker.substring(1));
    }
    return _decryptSignal(uid, ciphertextB64, typeMarker);
  }

  Future<String> _decryptSignal(String uid, String ciphertextB64, String typeMarker) async {
    final address = _addressFor(uid);
    final cipher = SessionCipher(_store, _store, _store, _store, address);
    final bytes = b64ToBytes(ciphertextB64);

    if (typeMarker == '3') {
      final message = PreKeySignalMessage(bytes);
      Uint8List? plaintext;
      await cipher.decryptWithCallback(message, (pt) {
        plaintext = pt;
      });
      if (plaintext == null) throw Exception('Could not decrypt message.');
      return utf8.decode(plaintext!);
    }

    // BUGFIX (this was the cause of the one-way-messaging bug — see the
    // fix notes): decrypting a plain (non-prekey) SignalMessage against an
    // already-established ratchet uses decryptFromSignalWithCallback, a
    // SEPARATELY named method from the PreKeySignalMessage path above
    // (confirmed directly against the libsignal_protocol_dart 0.8.2
    // source on GitHub — lib/src/session_cipher.dart — since this Dart
    // port can't overload a single method name by parameter type the way
    // Java's original libsignal does, it exposes two distinctly-named
    // methods instead: decryptWithCallback(PreKeySignalMessage, ...) for
    // a brand-new/handshake message, and
    // decryptFromSignalWithCallback(SignalMessage, ...) for every message
    // after a session is already established).
    //
    // The previous version of this method didn't know the real name and
    // guessed at several plausible-sounding ones via runtime reflection
    // (decryptSignalMessage, decryptWhisperMessage, decrypt,
    // decryptWithCallback with the wrong argument type) — none of which
    // exist on this class, so EVERY message sent over an already-
    // established session failed to decrypt. Concretely: the very first
    // message two people ever exchange is a PreKeySignalMessage (type
    // '3') and decrypted fine either way, but the Signal Protocol design
    // keeps the *initiating* side's messages tagged as PreKeySignalMessage
    // until it receives an actual reply — so in a conversation where only
    // one side ever successfully sent, that side's messages kept working
    // (always type '3'), while the other side's replies (type '1', a
    // plain SignalMessage once their session was fully established) could
    // never be decrypted at all. That's exactly the "person A can message
    // person B, but B can't message A back" symptom.
    final signalMessage = SignalMessage.fromSerialized(bytes);
    Uint8List? plaintext;
    await cipher.decryptFromSignalWithCallback(signalMessage, (pt) {
      plaintext = pt;
    });
    if (plaintext == null) throw Exception('Could not decrypt message.');
    return utf8.decode(plaintext!);
  }

  /// Feature: secret chats. Signs [message] with this device's Signal
  /// identity key so the other person can prove the handshake really came
  /// from us and wasn't swapped by anyone in the middle.
  Future<Uint8List> signWithIdentity(Uint8List message) async {
    final pair = await _store.getIdentityKeyPair();
    return Curve.calculateSignature(pair.getPrivateKey(), message);
  }

  /// Checks a signature made by [uid]'s identity key (the one pinned on this
  /// device, or their published one if no chat has happened yet).
  Future<bool> verifyPeerSignature(String uid, Uint8List message, Uint8List signature) async {
    final key = await peerIdentityPublicKeyBytes(uid);
    if (key == null) return false;
    return Curve.verifySignature(Curve.decodePoint(key, 0), message, signature);
  }

  /// This device's own identity public key — used only to build the
  /// safety-number / fingerprint comparison (see SafetyNumberService).
  /// This is already public information by design (it's the same key
  /// published at users/{uid}/signal/bundle.identityKey, see
  /// _publishBundle) — exposing it here just saves a round trip through
  /// Firestore to read back our own value.
  Future<Uint8List> myIdentityPublicKeyBytes() async {
    final pair = await _store.getIdentityKeyPair();
    return pair.getPublicKey().serialize();
  }

  /// [uid]'s identity public key. Prefers whatever this device currently
  /// has PINNED as trusted for them (see PersistentSignalProtocolStore) —
  /// so verifying shows the key actually in effect for this session, not
  /// necessarily whatever happens to be live in Firestore right this
  /// second (those two only ever differ right after a real key change,
  /// which is exactly the case the separate "Security code changed"
  /// dialog already covers). Falls back to fetching their published
  /// bundle directly if no session has been established with them yet.
  Future<Uint8List?> peerIdentityPublicKeyBytes(String uid) async {
    final pinned = await _store.getIdentity(_addressFor(uid));
    if (pinned != null) return pinned.serialize();
    final bundleDoc = await _bundleRef(uid).get();
    final data = bundleDoc.data();
    if (data == null) return null;
    return b64ToBytes(data['identityKey'] as String);
  }

  /// Feature: anti-tampering / MITM re-verification prompts. A pure,
  /// read-only comparison — pins nothing, trusts nothing, sends nothing.
  /// Returns true only when BOTH are true: (a) this device has already
  /// pinned a session for [uid] at some point (if there's no session
  /// yet, there's nothing to have "changed" from), and (b) the key
  /// currently published live for them no longer matches what's pinned.
  /// Safe to call proactively and often — opening a chat, opening the
  /// chat list, the app coming to the foreground — since it never
  /// touches the actual Double Ratchet session state the way encrypting/
  /// decrypting a real message does. The existing reactive path
  /// (IdentityChangedException, thrown from _ensureSession only when an
  /// actual SEND needs a brand-new session) still exists unchanged
  /// alongside this — this is what lets the warning show up BEFORE that
  /// point, e.g. the moment a chat is opened, rather than only after a
  /// send happens to fail.
  Future<bool> hasUnverifiedIdentityChange(String uid) async {
    final pinned = await _store.getIdentity(_addressFor(uid));
    if (pinned == null) return false;
    final bundleDoc = await _bundleRef(uid).get();
    final data = bundleDoc.data();
    if (data == null) return false;
    final liveKeyBytes = b64ToBytes(data['identityKey'] as String);
    final pinnedBytes = pinned.serialize();
    if (pinnedBytes.length != liveKeyBytes.length) return true;
    for (var i = 0; i < pinnedBytes.length; i++) {
      if (pinnedBytes[i] != liveKeyBytes[i]) return true;
    }
    return false;
  }

  String _myUidOrThrow() {
    final uid = _currentUid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  String? get _currentUid => _cachedUid;
  static String? _cachedUid;
  static void setCurrentUid(String? uid) => _cachedUid = uid;
}
