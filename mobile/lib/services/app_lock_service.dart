import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppLockService {
  static const _storage = FlutterSecureStorage();
  static const _pinKey = 'app_lock_pin';
  static const _enabledKey = 'app_lock_enabled';
  static const _hintKey = 'app_lock_pin_hint';

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: _enabledKey)) == 'true';
  }

  static Future<void> setPin(String pin, {String? hint}) async {
    await _storage.write(key: _pinKey, value: pin);
    await _storage.write(key: _enabledKey, value: 'true');
    if (hint != null && hint.trim().isNotEmpty) {
      await _storage.write(key: _hintKey, value: hint.trim());
    } else {
      await _storage.delete(key: _hintKey);
    }
  }

  static Future<String?> getHint() => _storage.read(key: _hintKey);

  static Future<void> disable() async {
    await _storage.delete(key: _pinKey);
    await _storage.delete(key: _hintKey);
    await _storage.write(key: _enabledKey, value: 'false');
  }

  static Future<bool> verify(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    return stored != null && stored == pin;
  }

  static Future<void> resetAfterAccountVerification() => disable();
}
