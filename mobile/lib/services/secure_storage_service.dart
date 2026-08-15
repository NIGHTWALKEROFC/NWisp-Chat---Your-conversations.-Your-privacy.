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

  static Future<void> clearAll() => _storage.deleteAll();
}
