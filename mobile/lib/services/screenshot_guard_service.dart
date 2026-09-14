import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper around a tiny native MethodChannel (see MainActivity.kt)
/// that toggles Android's FLAG_SECURE on this app's window — the same
/// flag Signal and WhatsApp use to block screenshots and screen
/// recording. No-op on any platform other than Android (FLAG_SECURE is an
/// Android-only concept — this app is Android-only per pubspec.yaml, but
/// the guard is written defensively so it degrades to doing nothing
/// rather than crashing if that ever changes).
///
/// This protection is ALWAYS ON, everywhere, for every chat, group, and
/// sensitive screen — there is deliberately no setting to turn it off,
/// globally or per-chat. It used to be optional (see the old
/// ScreenshotSettingsService, removed) but that meant one person could
/// quietly opt out of protecting a conversation the OTHER person in it
/// never agreed to expose — their privacy was never this device owner's
/// to trade away. So this is back to unconditional, matching the
/// original always-on design, and ScreenshotSettingsService and every
/// "Block screenshots" toggle that read from it have been deleted.
///
/// FLAG_SECURE is a single flag on the whole app window, not something
/// Android lets you set "for just this screen" — so instead of naively
/// setting it on a chat screen's initState and clearing it on dispose
/// (which would incorrectly turn protection OFF while a protected screen
/// is still further down the navigation stack, e.g. a fullscreen image
/// viewer pushed on top of a chat), this keeps a simple reference count.
/// Protection stays on as long as at least one screen that asked for it
/// is still alive anywhere in the stack.
class ScreenshotGuardService {
  ScreenshotGuardService._();

  static const _channel = MethodChannel('com.nightwalker.securechat/screenshot_guard');
  static int _activeCount = 0;

  /// Call from initState() of any screen that should never be
  /// screenshotted or screen-recorded (1:1 chat, group chat, fullscreen
  /// media viewers, the safety-number verification screen). Must be
  /// paired with exactly one [release] call, normally from dispose().
  static Future<void> acquire() async {
    _activeCount++;
    if (_activeCount == 1) {
      await _setSecure(true);
    }
  }

  /// Call from dispose() of a screen that previously called [acquire].
  static Future<void> release() async {
    if (_activeCount == 0) return; // defensive — a mismatched release should never go negative
    _activeCount--;
    if (_activeCount == 0) {
      await _setSecure(false);
    }
  }

  static Future<void> _setSecure(bool secure) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod(secure ? 'enable' : 'disable');
    } catch (_) {
      // Best-effort — a channel hiccup shouldn't crash a chat screen over
      // a defense-in-depth feature. Worst case, this one screen isn't
      // screenshot-blocked this one time.
    }
  }
}
