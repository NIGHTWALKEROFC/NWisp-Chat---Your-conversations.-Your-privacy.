import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Feature: screenshot/screen-recording protection, made optional
/// (2026-09-11) — it used to be permanently on for every chat and group
/// with no way to turn it off. Now: a global default (ON, matching the
/// old always-on behavior for anyone who never touches this) that can be
/// turned off in Settings, PLUS a per-chat/per-group override so turning
/// it off globally doesn't force it off somewhere you specifically want
/// it, and vice versa — turning it on globally doesn't stop you from
/// switching it off for one specific chat. See ScreenshotGuardService for
/// where this actually gets enforced (it does the FLAG_SECURE work; this
/// class is just where the ON/OFF choice lives).
///
/// Device-local only (SharedPreferences) — same as AppLockService, not
/// account-scoped. A screenshot restriction is about THIS device, not
/// about who's signed in on it.
class ScreenshotSettingsService {
  ScreenshotSettingsService._();

  static const _globalKey = 'screenshot_protection_global_enabled'; // bool, default true
  static const _overridesKey = 'screenshot_protection_overrides'; // JSON: {conversationId: bool}

  static Future<bool> isGlobalEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_globalKey) ?? true;
  }

  static Future<void> setGlobalEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_globalKey, value);
  }

  static Future<Map<String, bool>> _loadOverrides() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_overridesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, bool>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveOverrides(Map<String, bool> overrides) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_overridesKey, jsonEncode(overrides));
  }

  /// Null means "no override — follows the global default".
  static Future<bool?> getOverride(String conversationId) async {
    final overrides = await _loadOverrides();
    return overrides[conversationId];
  }

  /// Pass null to clear the override and go back to following the global
  /// default for this chat/group.
  static Future<void> setOverride(String conversationId, bool? value) async {
    final overrides = await _loadOverrides();
    if (value == null) {
      overrides.remove(conversationId);
    } else {
      overrides[conversationId] = value;
    }
    await _saveOverrides(overrides);
  }

  /// What ScreenshotGuardService actually checks: this chat's own
  /// override if it has one, otherwise the global default.
  static Future<bool> isEnabledFor(String conversationId) async {
    final override = await getOverride(conversationId);
    if (override != null) return override;
    return isGlobalEnabled();
  }
}
