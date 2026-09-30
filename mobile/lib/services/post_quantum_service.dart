import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' show Curve, IdentityKeyPair;
import 'mlkem768.dart';

/// Thrown when strict mode (or a secret chat) needs post-quantum protection
/// for a contact who has no post-quantum key yet, or when this phone's
/// post-quantum self-test failed.
class PostQuantumUnavailableException implements Exception {
  final String message;
  PostQuantumUnavailableException(this.message);
  @override
  String toString() => message;
}

/// Thrown when a contact's published post-quantum key does NOT carry a valid
/// signature from their identity key — that means someone tampered with it,
/// so the message is never sent (there is no silent fallback for this case).
class PostQuantumTamperException implements Exception {
  @override
  String toString() =>
      "This contact's post-quantum key failed its signature check, so nothing was sent. Compare safety numbers with them.";
}

/// Post-quantum layer on top of the Signal Double Ratchet.
///
/// Every message the Double Ratchet produces is wrapped once more:
///
///   * the sender runs ML-KEM-768 against the recipient's published
///     post-quantum public key and gets a fresh 32-byte secret,
///   * HKDF-SHA256 turns that secret into a one-message AES-256-GCM key,
///   * the Double Ratchet ciphertext is sealed with that key.
///
/// To read a message, an attacker must break BOTH the classical
/// X25519 Double Ratchet AND ML-KEM-768. A future quantum computer that
/// breaks X25519 therefore still can't read recorded traffic ("harvest now,
/// decrypt later"). This is the same hybrid idea Signal uses in PQXDH, done
/// as an outer envelope because the Signal library this app uses has no
/// post-quantum support.
///
/// Each phone publishes a signed ML-KEM public key at
/// users/{uid}/signal/pq. The signature comes from the account's Signal
/// identity key, so the server can't swap in its own key unnoticed. Keys
/// rotate every 7 days; old private keys are kept 30 days so late messages
/// still open, then deleted (which is what gives the post-quantum layer
/// forward secrecy).
///
/// Envelope: 0x01 | keyId (8) | ML-KEM ciphertext (1088) | nonce (12) |
/// AES-GCM ciphertext + tag. Bound as AAD: version, keyId, sender, receiver.
class PostQuantumService {
  PostQuantumService._();
  static final instance = PostQuantumService._();

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _keysKey = 'pq_keys_v1';
  static const _strictKey = 'pq_strict_v1';
  static const _rotateAfter = Duration(days: 7);
  static const _keepFor = Duration(days: 30);
  static const _version = 0x01;

  final _aes = AesGcm.with256bits();
  final _rand = Random.secure();

  bool? _available;
  bool _strict = false;
  bool _strictLoaded = false;
  List<_LocalPqKey>? _keys;
  final Map<String, _CachedPeerKey> _peerCache = {};

  /// True only if the ML-KEM known-answer self-test passed on this phone.
  bool get available => _available ??= MlKem768.selfTest();

  Future<bool> isStrict() async {
    if (!_strictLoaded) {
      _strict = (await _storage.read(key: _strictKey)) == '1';
      _strictLoaded = true;
    }
    return _strict;
  }

  /// Strict mode: refuse to send anything to a contact who can't receive the
  /// post-quantum layer, instead of quietly sending classical-only.
  Future<void> setStrict(bool value) async {
    _strict = value;
    _strictLoaded = true;
    await _storage.write(key: _strictKey, value: value ? '1' : '0');
  }

  Uint8List _randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rand.nextInt(256)));

  // ------------------------------------------------------- local key store
  Future<List<_LocalPqKey>> _loadKeys() async {
    if (_keys != null) return _keys!;
    final raw = await _storage.read(key: _keysKey);
    if (raw == null || raw.isEmpty) {
      _keys = [];
    } else {
      try {
        _keys = (jsonDecode(raw) as List).map((e) => _LocalPqKey.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        _keys = [];
      }
    }
    return _keys!;
  }

  Future<void> _saveKeys() => _storage.write(key: _keysKey, value: jsonEncode(_keys!.map((k) => k.toJson()).toList()));

  /// Forget every post-quantum key on this phone (used when a different
  /// account signs in — see SignalSessionService.wipe).
  Future<void> wipe() async {
    _keys = null;
    _peerCache.clear();
    await _storage.delete(key: _keysKey);
  }

  static String _idOf(List<int> ek) => bytesToHex(MlKem768.sha3_256(ek).sublist(0, 8));
  static String bytesToHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List hexToBytes(String h) =>
      Uint8List.fromList(List<int>.generate(h.length ~/ 2, (i) => int.parse(h.substring(2 * i, 2 * i + 2), radix: 16)));

  Uint8List _signedBytes(String uid, List<int> ek) => Uint8List.fromList(utf8.encode('NWisp-PQ-EK-v1|$uid|') + ek);

  DocumentReference<Map<String, dynamic>> _pqDoc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('signal').doc('pq');

  /// Call after the Signal identity exists (SignalSessionService.install).
  /// Creates the first key, or rotates when the current one is a week old,
  /// publishes the public half signed by [identityKeyPair], and deletes
  /// private keys older than 30 days. Never throws — a failure just means
  /// contacts fall back to classical-only until the next app start.
  Future<void> ensurePublished({required String uid, required IdentityKeyPair identityKeyPair}) async {
    try {
      if (!available) return;
      final keys = await _loadKeys();
      final now = DateTime.now();
      keys.removeWhere((k) => now.difference(k.createdAt) > _keepFor);
      final current = keys.isEmpty ? null : keys.last;
      if (current != null && now.difference(current.createdAt) < _rotateAfter) {
        // Make sure what's published still matches (e.g. after a reinstall of Firestore data).
        final snap = await _pqDoc(uid).get();
        if (snap.data()?['keyId'] == current.id) return;
        await _publish(uid, identityKeyPair, current);
        return;
      }
      final (ek, dk) = MlKem768.keyGen(_randomBytes(64));
      final fresh = _LocalPqKey(id: _idOf(ek), ek: ek, dk: dk, createdAt: now);
      keys.add(fresh);
      await _saveKeys();
      await _publish(uid, identityKeyPair, fresh);
    } catch (_) {}
  }

  Future<void> _publish(String uid, IdentityKeyPair pair, _LocalPqKey key) async {
    final sig = Curve.calculateSignature(pair.getPrivateKey(), _signedBytes(uid, key.ek));
    await _pqDoc(uid).set({
      'keyId': key.id,
      'ek': base64Encode(key.ek),
      'sig': base64Encode(sig),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ------------------------------------------------------------ peer keys
  /// Fetches and verifies [peerUid]'s post-quantum public key. Returns null
  /// when they haven't published one (an older app version).
  /// [identityKeyBytes] is their Signal identity public key (33 bytes).
  Future<({Uint8List ek, String id})?> _peerKey(String peerUid, Uint8List identityKeyBytes) async {
    final cached = _peerCache[peerUid];
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 10)) {
      return (ek: cached.ek, id: cached.id);
    }
    final snap = await _pqDoc(peerUid).get();
    final data = snap.data();
    if (data == null || data['ek'] is! String || data['sig'] is! String) return null;
    final ek = base64Decode(data['ek'] as String);
    if (ek.length != MlKem768.publicKeyLength) throw PostQuantumTamperException();
    final sig = base64Decode(data['sig'] as String);
    final ok = Curve.verifySignature(Curve.decodePoint(identityKeyBytes, 0), _signedBytes(peerUid, ek), sig);
    if (!ok) throw PostQuantumTamperException();
    final id = _idOf(ek);
    _peerCache[peerUid] = _CachedPeerKey(ek: Uint8List.fromList(ek), id: id, at: DateTime.now());
    return (ek: Uint8List.fromList(ek), id: id);
  }

  /// The public post-quantum key of [peerUid] plus its id, verified — used
  /// by secret chats, which need it for the live handshake.
  Future<Uint8List?> verifiedPeerEk(String peerUid, Uint8List identityKeyBytes) async =>
      (await _peerKey(peerUid, identityKeyBytes))?.ek;

  // ------------------------------------------------------------ wrap/unwrap
  Future<SecretKey> _messageKey(List<int> shared, List<int> keyId, String from, String to) {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: utf8.encode('NWisp-PQ-salt-v1'),
      info: utf8.encode('NWisp-PQ-msg-v1|$from|$to|') + keyId,
    );
  }

  List<int> _aad(List<int> keyId, String from, String to) => [_version, ...keyId, ...utf8.encode('$from>$to')];

  /// Wraps [inner] (a Double Ratchet ciphertext) for [peerUid]. Returns null
  /// if the contact has no post-quantum key and strictness isn't required.
  Future<Uint8List?> wrapForPeer({
    required String myUid,
    required String peerUid,
    required Uint8List peerIdentityKey,
    required Uint8List inner,
    bool requirePq = false,
  }) async {
    final strict = requirePq || await isStrict();
    if (!available) {
      if (strict) throw PostQuantumUnavailableException("Post-quantum protection isn't working on this phone, so strict mode blocked the send.");
      return null;
    }
    final peer = await _peerKey(peerUid, peerIdentityKey);
    if (peer == null) {
      if (strict) {
        throw PostQuantumUnavailableException(
          "This contact hasn't got post-quantum protection yet (they need to update and open NWisp). Strict mode blocked the send.",
        );
      }
      return null;
    }
    final (shared, kemCt) = MlKem768.encapsulate(peer.ek, _randomBytes(32));
    final keyId = hexToBytes(peer.id);
    final key = await _messageKey(shared, keyId, myUid, peerUid);
    final nonce = _randomBytes(12);
    final box = await _aes.encrypt(inner, secretKey: key, nonce: nonce, aad: _aad(keyId, myUid, peerUid));
    final out = BytesBuilder()
      ..addByte(_version)
      ..add(keyId)
      ..add(kemCt)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Opens an envelope made by [wrapForPeer]; returns the Double Ratchet
  /// ciphertext inside.
  Future<Uint8List> unwrapFromPeer({required String myUid, required String peerUid, required Uint8List envelope}) async {
    if (!available) throw PostQuantumUnavailableException("Post-quantum protection isn't working on this phone.");
    const header = 1 + 8 + MlKem768.ciphertextLength + 12;
    if (envelope.length < header + 16 || envelope[0] != _version) {
      throw Exception('Unsupported post-quantum envelope.');
    }
    final keyId = envelope.sublist(1, 9);
    final kemCt = envelope.sublist(9, 9 + MlKem768.ciphertextLength);
    final nonce = envelope.sublist(9 + MlKem768.ciphertextLength, header);
    final body = envelope.sublist(header);
    final id = bytesToHex(keyId);
    final keys = await _loadKeys();
    final match = keys.where((k) => k.id == id).toList();
    if (match.isEmpty) throw Exception('The post-quantum key for this message has already been deleted.');
    final shared = MlKem768.decapsulate(match.first.dk, kemCt);
    final key = await _messageKey(shared, keyId, peerUid, myUid);
    final box = SecretBox(body.sublist(0, body.length - 16), nonce: nonce, mac: Mac(body.sublist(body.length - 16)));
    final clear = await _aes.decrypt(box, secretKey: key, aad: _aad(keyId, peerUid, myUid));
    return Uint8List.fromList(clear);
  }

  /// Short human-readable status for the Encryption screen.
  Future<String> currentKeyId() async {
    final keys = await _loadKeys();
    return keys.isEmpty ? '—' : keys.last.id;
  }
}

class _LocalPqKey {
  final String id;
  final Uint8List ek;
  final Uint8List dk;
  final DateTime createdAt;
  _LocalPqKey({required this.id, required this.ek, required this.dk, required this.createdAt});

  Map<String, dynamic> toJson() => {
        'id': id,
        'ek': base64Encode(ek),
        'dk': base64Encode(dk),
        't': createdAt.millisecondsSinceEpoch,
      };

  factory _LocalPqKey.fromJson(Map<String, dynamic> j) => _LocalPqKey(
        id: j['id'] as String,
        ek: base64Decode(j['ek'] as String),
        dk: base64Decode(j['dk'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
      );
}

class _CachedPeerKey {
  final Uint8List ek;
  final String id;
  final DateTime at;
  _CachedPeerKey({required this.ek, required this.id, required this.at});
}
