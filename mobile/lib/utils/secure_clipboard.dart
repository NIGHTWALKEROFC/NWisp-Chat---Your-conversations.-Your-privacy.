import 'package:flutter/services.dart';

/// Feature: clipboard auto-clear for sensitive values (generated
/// passwords, OTP codes). A normal `Clipboard.setData` call leaves the
/// value sitting in the system clipboard — readable by any other app on
/// the device — until something else happens to overwrite it, which
/// could be minutes, hours, or never. This wraps that with a timer that
/// wipes it back out again shortly after.
class SecureClipboard {
  /// Copies [value] to the clipboard, then clears it again after
  /// [after] (default 45 seconds) — but ONLY if the clipboard still
  /// contains exactly [value] at that point. That check matters: if the
  /// person copied something else in the meantime, this must never wipe
  /// THAT out instead — it only ever cleans up after itself.
  static Future<void> copyWithAutoClear(String value, {Duration after = const Duration(seconds: 45)}) async {
    await Clipboard.setData(ClipboardData(text: value));
    Future.delayed(after, () async {
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        if (current?.text == value) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        // Best-effort — clipboard access can fail (e.g. app backgrounded
        // on some platforms); nothing to do if so.
      }
    });
  }
}
