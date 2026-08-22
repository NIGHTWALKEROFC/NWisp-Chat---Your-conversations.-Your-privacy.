import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'secure_storage_service.dart';

/// Local-at-rest encryption for the on-device SQLite message store, and
/// per-file encryption for chat media. Peer-to-peer message encryption
/// used to live here too (a static-key X25519 scheme), but that's now
/// handled by SignalSessionService's Double Ratchet instead, which gives
/// per-message forward secrecy this static scheme never had.
class CryptoService {
  static final _aesGcm = AesGcm.with256bits();

  static SecretKey? _localStorageKey;

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

  /// Drops the in-memory local storage key without touching secure storage
  /// — used right before SessionService reloads it for a newly active
  /// account, so nothing from the previous account can accidentally still
  /// be used mid-transition.
  static void clearInMemoryKeys() {
    _localStorageKey = null;
  }

  static Uint8ListLike _randomNonce() {
    final rand = Random.secure();
    return List<int>.generate(12, (_) => rand.nextInt(256));
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

  // --- Chat media (images/video/voice) --------------------------------
  //
  // Media gets its own random, single-use AES-256-GCM key per file — NOT
  // the local storage key. The file itself (usually hundreds of KB to a
  // few MB) is encrypted once with this random key; only the *key* (32
  // bytes) travels through SignalSessionService's Double Ratchet inside
  // the message_relay row. Supabase Storage therefore only ever holds
  // bytes it cannot decrypt — the encryption key never touches Supabase.

  /// A fresh random 256-bit key for encrypting one file. Base64-encoded so
  /// it can be embedded directly in the small JSON payload that gets
  /// encrypted for the recipient via SignalSessionService.encryptForPeer.
  static Future<String> generateFileKey() async {
    final key = await _aesGcm.newSecretKey();
    return base64Encode(await key.extractBytes());
  }

  static Future<(List<int>, String)> encryptFileBytes(List<int> plaintext, String fileKeyB64) async {
    final key = SecretKey(base64Decode(fileKeyB64));
    final nonce = _randomNonce();
    final box = await _aesGcm.encrypt(plaintext, secretKey: key, nonce: nonce);
    return ([...box.cipherText, ...box.mac.bytes], base64Encode(nonce));
  }

  static Future<List<int>> decryptFileBytes(List<int> combined, String nonceB64, String fileKeyB64) async {
    final key = SecretKey(base64Decode(fileKeyB64));
    final cipherBytes = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final box = SecretBox(cipherBytes, nonce: base64Decode(nonceB64), mac: Mac(macBytes));
    return _aesGcm.decrypt(box, secretKey: key);
  }
}

typedef Uint8ListLike = List<int>;
