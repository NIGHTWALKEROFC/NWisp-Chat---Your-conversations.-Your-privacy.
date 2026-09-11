import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'screenshot_settings_service.dart';

/// Thin wrapper around a tiny native MethodChannel (see MainActivity.kt)
/// that toggles Android's FLAG_SECURE on this app's window — the same
/// flag Signal and WhatsApp use to block screenshots and screen
/// recording. No-op on any platform other than Android (FLAG_SECURE is an
/// Android-only concept — this app is Android-only per pubspec.yaml, but
/// the guard is written defensively so it degrades to doing nothing
/// rather than crashing if that ever changes).
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
  /// paired with exactly one [release] call, normally from dispose(),
  /// passing the SAME [conversationId] (or leaving it null both times).
  ///
  /// [conversationId]: made this optional (2026-09-11) — pass a chat/group
  /// id to make protection respect that conversation's own screenshot
  /// setting (see ScreenshotSettingsService); leave it null for anything
  /// that isn't tied to one specific conversation (the safety-number
  /// screen, a standalone media viewer) — those keep the old
  /// always-protect behavior unconditionally, same as before this
  /// setting existed.
  static Future<void> acquire({String? conversationId}) async {
    if (conversationId != null && !await ScreenshotSettingsService.isEnabledFor(conversationId)) {
      return; // this conversation opted out — don't even join the reference count
    }
    _activeCount++;
    if (_activeCount == 1) {
      await _setSecure(true);
    }
  }

  /// Call from dispose() of a screen that previously called [acquire] —
  /// with the same [conversationId] argument (or lack of one) it used
  /// there, so this can tell whether that acquire() actually joined the
  /// reference count or opted out.
  static Future<void> release({String? conversationId}) async {
    if (conversationId != null && !await ScreenshotSettingsService.isEnabledFor(conversationId)) {
      return; // mirrors whatever acquire() decided — nothing to release
    }
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
