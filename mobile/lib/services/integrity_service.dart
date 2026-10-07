import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'app_version.dart';
import 'update_config.dart';

/// Facts about this installed copy of the app, from the Android side.
class AppInfo {
  final int versionCode;
  final String versionName;
  final List<String> certs;
  final bool debuggable;
  final String? installer;
  const AppInfo({required this.versionCode, required this.versionName, required this.certs, required this.debuggable, this.installer});
}

/// Feature: update guard — the "is this the real NWisp?" half.
///
/// Reads the app's own version and the fingerprint of the key it is signed
/// with. If you set EXPECTED_CERT_SHA256 when building, a copy signed with any
/// other key (which is what happens when someone edits and re-signs the APK)
/// is treated as modified: the app shows a notice and closes.
///
/// HONEST LIMIT: this raises the effort a lot, but a skilled person can edit
/// the app to skip any check that lives inside it. That is why the server also
/// enforces the minimum version (see supabase/functions/_shared/version_gate.ts)
/// and why several different parts of the app check this independently.
class IntegrityService extends ChangeNotifier {
  IntegrityService._();
  static final instance = IntegrityService._();

  static const _channel = MethodChannel('com.nightwalker.securechat/integrity');
  static const _storage = FlutterSecureStorage();
  static const _flagKey = 'copy_check_failed';

  AppInfo? info;
  bool _tampered = false;
  bool get tampered => _tampered;

  Future<void> init() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('appInfo');
      if (raw != null && raw['error'] == null) {
        info = AppInfo(
          versionCode: (raw['versionCode'] as num?)?.toInt() ?? 0,
          versionName: (raw['versionName'] as String?) ?? '',
          certs: List<String>.from((raw['certs'] as List?) ?? const []),
          debuggable: raw['debuggable'] == true,
          installer: raw['installer'] as String?,
        );
        AppVersion.code = info!.versionCode;
        AppVersion.name = info!.versionName;
      }
    } catch (e) {
      debugPrint('IntegrityService.init: $e');
    }
    try {
      if (await _storage.read(key: _flagKey) == '1') _tampered = true;
    } catch (_) {}
    if (!_tampered) await _verify();
    if (_tampered) notifyListeners();
  }

  Future<void> _verify() async {
    final i = info;
    if (i == null) return; // couldn't read — never punish an honest user for that
    final expected = kExpectedCertSha256
        .split(',')
        .map((s) => s.trim().toLowerCase().replaceAll(':', ''))
        .where((s) => s.isNotEmpty)
        .toSet();
    var bad = false;
    if (expected.isNotEmpty && i.certs.isNotEmpty) {
      // Every key the app is signed with must be one you listed.
      bad = !i.certs.every(expected.contains);
    }
    // A release build that claims to be debuggable has been edited.
    if (kReleaseMode && i.debuggable) bad = true;
    if (bad) {
      _tampered = true;
      try {
        await _storage.write(key: _flagKey, value: '1');
      } catch (_) {}
    }
  }

  /// Shows nothing itself — the gate widget shows the notice. This ends the
  /// app a few seconds later.
  Future<void> closeApp() async {
    try {
      await SystemNavigator.pop();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 600));
    try {
      await _channel.invokeMethod('killProcess');
    } catch (_) {}
  }
}
