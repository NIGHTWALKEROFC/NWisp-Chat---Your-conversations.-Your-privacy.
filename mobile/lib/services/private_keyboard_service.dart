import 'package:flutter/foundation.dart';
import 'settings_service.dart';

/// Feature: private keyboard mode. OFF by default; turned on in
/// Settings > Privacy.
///
/// When on, every message box and search box in the app asks the keyboard
/// (the phone's keyboard app, not this app) to:
///   * not learn from what's typed here  (enableIMEPersonalizedLearning)
///   * not show word suggestions          (enableSuggestions)
///   * not auto-correct                   (autocorrect)
///
/// Honest limit: this is a REQUEST to the keyboard app. Gboard and most
/// mainstream keyboards honour it; a keyboard that ignores the request can't
/// be forced to. Password and PIN fields already ask for this regardless.
class PrivateKeyboardService {
  PrivateKeyboardService._();

  /// Read `.value` inside build() and pass the three flags into a TextField:
  ///   enableSuggestions: !PrivateKeyboardService.enabled.value
  ///   autocorrect: !PrivateKeyboardService.enabled.value
  ///   enableIMEPersonalizedLearning: !PrivateKeyboardService.enabled.value
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// Called once at startup (main.dart) to load the saved choice.
  static Future<void> load() async {
    enabled.value = await SettingsService.getPrivateKeyboardEnabled();
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    await SettingsService.setPrivateKeyboardEnabled(value);
  }
}
