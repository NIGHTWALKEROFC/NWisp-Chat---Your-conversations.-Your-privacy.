import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> saveLocalStorageKey(String key) =>
      _storage.write(key: 'local_storage_key', value: key);

  static Future<String?> getLocalStorageKey() => _storage.read(key: 'local_storage_key');

  /// Which Firebase uid this device's local storage key / Signal Protocol
  /// identity currently belong to. Used by SessionService to detect "a
  /// different account just signed in on this device" and wipe the
  /// previous account's keys before anything for the new one is loaded or
  /// generated.
  static Future<void> setActiveUid(String uid) => _storage.write(key: 'active_uid', value: uid);

  static Future<String?> getActiveUid() => _storage.read(key: 'active_uid');

  /// Stable per-install identifier for THIS device — used by
  /// DeviceSessionService to tell "is this still the device the account is
  /// active on, or has a different device signed in since." Persists
  /// across app restarts, but not across an uninstall/reinstall (a fresh
  /// install is treated as a new device, which is the correct behaviour).
  static Future<void> saveDeviceId(String id) => _storage.write(key: 'device_id', value: id);

  static Future<String?> getDeviceId() => _storage.read(key: 'device_id');

  static Future<void> clearAll() => _storage.deleteAll();
}
