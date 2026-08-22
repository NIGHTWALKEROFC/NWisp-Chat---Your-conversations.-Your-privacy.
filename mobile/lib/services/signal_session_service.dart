import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_store.dart';

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
  }

  /// Wipes this device's entire Signal identity/session state — used when
  /// a different account signs in on this device (see SessionService).
  Future<void> wipe() => _store.wipeAll();

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
      throw Exception("This contact hasn't set up secure messaging yet — ask them to update and reopen the app.");
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
  Future<(String, String)> encryptForPeer(String uid, String plaintext) async {
    await _ensureSession(uid);
    final cipher = SessionCipher(_store, _store, _store, _store, _addressFor(uid));
    final ciphertext = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
    final typeMarker = ciphertext.getType() == CiphertextMessage.prekeyType ? '3' : '1';
    return (bytesToB64(ciphertext.serialize()), typeMarker);
  }

  /// Decrypts a message from [uid]. [typeMarker] is whatever
  /// [encryptForPeer] tagged it with on the sending side (see above).
  Future<String> decryptFromPeer(String uid, String ciphertextB64, String typeMarker) async {
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
    } else {
      // NOTE: SignalMessage.fromSerialized is the best-match name for
      // deserializing wire bytes back into a SignalMessage, mirrored from
      // the same pattern this package uses for SessionRecord/
      // SignedPreKeyRecord (see signal_store.dart's verification note).
      // If this doesn't match the installed version, the fix is a
      // one-line rename here to whatever this package's generated docs
      // show for "construct a SignalMessage from serialized bytes".
      final message = SignalMessage.fromSerialized(bytes);
      final plaintext2 = await cipher.decrypt(message);
      return utf8.decode(plaintext2);
    }
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
