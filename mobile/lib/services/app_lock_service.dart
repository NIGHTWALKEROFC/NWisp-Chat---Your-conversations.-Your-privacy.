import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A local PIN required to open the app, on top of your account password.
/// Stored in flutter_secure_storage, which is backed by Android Keystore /
/// iOS Keychain — the same encrypted-at-rest storage already used for other
/// sensitive values in this app, so no new dependency is needed.
///
/// This protects against someone picking up an unlocked phone and opening
/// the app; it is not a replacement for your account password.
class AppLockService {
  static const _storage = FlutterSecureStorage();
  static const _pinKey = 'app_lock_pin';
  static const _enabledKey = 'app_lock_enabled';

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: _enabledKey)) == 'true';
  }

  static Future<void> setPin(String pin) async {
    await _storage.write(key: _pinKey, value: pin);
    await _storage.write(key: _enabledKey, value: 'true');
  }

  static Future<void> disable() async {
    await _storage.delete(key: _pinKey);
    await _storage.write(key: _enabledKey, value: 'false');
  }

  static Future<bool> verify(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    return stored != null && stored == pin;
  }
}
