import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> saveIdentityKeyPair(String serializedKeyPair) =>
      _storage.write(key: 'identity_keypair', value: serializedKeyPair);

  static Future<String?> getIdentityKeyPair() => _storage.read(key: 'identity_keypair');

  static Future<void> saveLocalStorageKey(String key) =>
      _storage.write(key: 'local_storage_key', value: key);

  static Future<String?> getLocalStorageKey() => _storage.read(key: 'local_storage_key');

  /// Which Firebase uid this device's identity key pair / local storage key
  /// currently belong to. Used by SessionService to detect "a different
  /// account just signed in on this device" and wipe the previous account's
  /// keys before anything for the new one is loaded or generated.
  static Future<void> setActiveUid(String uid) => _storage.write(key: 'active_uid', value: uid);

  static Future<String?> getActiveUid() => _storage.read(key: 'active_uid');

  static Future<void> clearAll() => _storage.deleteAll();
}
