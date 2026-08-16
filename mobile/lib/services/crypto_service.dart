import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'secure_storage_service.dart';

/// End-to-end encryption for message content, and a separate device-local
/// key for encrypting what's stored on disk.
///
/// Transit scheme: X25519 (ECDH) between the sender's and recipient's static
/// key pairs -> HKDF -> AES-256-GCM. This is standard, well-audited-primitive
/// encryption, but it is a *static-key* scheme (no Double Ratchet), so it
/// does not have per-message forward secrecy the way Signal/WhatsApp's full
/// protocol does. See the note in the main writeup for the upgrade path.
class CryptoService {
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static SimpleKeyPair? _myKeyPair;
  static SecretKey? _localStorageKey;

  /// Call once at app startup (after sign-in). Generates this device's
  /// identity key pair the first time, or loads it from secure storage.
  /// Returns the base64 public key so the caller can publish it.
  static Future<String> ensureIdentityKeyPair() async {
    final existing = await SecureStorageService.getIdentityKeyPair();
    if (existing != null) {
      final seed = base64Decode(existing);
      _myKeyPair = await _x25519.newKeyPairFromSeed(seed);
    } else {
      _myKeyPair = await _x25519.newKeyPair();
      final seed = await (_myKeyPair as SimpleKeyPair).extractPrivateKeyBytes();
      await SecureStorageService.saveIdentityKeyPair(base64Encode(seed));
    }
    final pub = await _myKeyPair!.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  /// Call once at app startup. Generates (once) or loads the AES key used
  /// only to encrypt this device's local SQLite copy of messages.
  static Future<void> ensureLocalStorageKey() async {
    final existing = await SecureStorageService.getLocalStorageKey();
    if (existing != null) {
      _localStorageKey = SecretKey(base64Decode(existing));
      return;
    }
    final key = await _aesGcm.newSecretKey();
    final bytes = await key.extractBytes();
    await SecureStorageService.saveLocalStorageKey(base64Encode(bytes));
    _localStorageKey = key;
  }

  /// Drops the in-memory copies of both keys without touching secure
  /// storage — used right before SessionService reloads/regenerates them
  /// for a newly active account, so nothing from the previous account can
  /// accidentally still be used mid-transition.
  static void clearInMemoryKeys() {
    _myKeyPair = null;
    _localStorageKey = null;
  }

  static Uint8ListLike _randomNonce() {
    final rand = Random.secure();
    return List<int>.generate(12, (_) => rand.nextInt(256));
  }

  /// Encrypts [plaintext] so only the holder of [peerPublicKeyB64]'s matching
  /// private key can read it. Returns (ciphertextB64, nonceB64).
  static Future<(String, String)> encryptForPeer(String plaintext, String peerPublicKeyB64) async {
    final peerPublicKey = SimplePublicKey(base64Decode(peerPublicKeyB64), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: _myKeyPair!, remotePublicKey: peerPublicKey);
    final aesKey = await _hkdf.deriveKey(secretKey: shared, info: utf8.encode('nwisp-msg-v1'));
    final nonce = _randomNonce();
    final box = await _aesGcm.encrypt(utf8.encode(plaintext), secretKey: aesKey, nonce: nonce);
    final combined = [...box.cipherText, ...box.mac.bytes];
    return (base64Encode(combined), base64Encode(nonce));
  }

  /// Decrypts a message that [senderPublicKeyB64] encrypted for us.
  static Future<String> decryptFromPeer({
    required String ciphertextB64,
    required String nonceB64,
    required String senderPublicKeyB64,
  }) async {
    final senderPublicKey = SimplePublicKey(base64Decode(senderPublicKeyB64), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: _myKeyPair!, remotePublicKey: senderPublicKey);
    final aesKey = await _hkdf.deriveKey(secretKey: shared, info: utf8.encode('nwisp-msg-v1'));
    final combined = base64Decode(ciphertextB64);
    final cipherBytes = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final box = SecretBox(cipherBytes, nonce: base64Decode(nonceB64), mac: Mac(macBytes));
    final clear = await _aesGcm.decrypt(box, secretKey: aesKey);
    return utf8.decode(clear);
  }

  /// Local-at-rest encryption for the SQLite copy (device-local key only).
  static Future<(String, String)> encryptLocal(String plaintext) async {
    final nonce = _randomNonce();
    final box = await _aesGcm.encrypt(utf8.encode(plaintext), secretKey: _localStorageKey!, nonce: nonce);
    final combined = [...box.cipherText, ...box.mac.bytes];
    return (base64Encode(combined), base64Encode(nonce));
  }

  static Future<String> decryptLocal(String ciphertextB64, String nonceB64) async {
    final combined = base64Decode(ciphertextB64);
    final cipherBytes = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final box = SecretBox(cipherBytes, nonce: base64Decode(nonceB64), mac: Mac(macBytes));
    final clear = await _aesGcm.decrypt(box, secretKey: _localStorageKey!);
    return utf8.decode(clear);
  }
}

typedef Uint8ListLike = List<int>;
