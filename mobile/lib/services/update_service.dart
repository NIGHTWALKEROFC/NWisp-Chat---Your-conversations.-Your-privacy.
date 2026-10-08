import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_version.dart';
import 'integrity_service.dart';
import 'update_config.dart';

class ReleaseNote {
  final String versionName;
  final String releaseDate;
  final List<String> notes;
  const ReleaseNote(this.versionName, this.releaseDate, this.notes);
}

class MirrorLink {
  final String label;
  final String url;
  const MirrorLink(this.label, this.url);
}

/// One downloadable APK file with the checksum the signed update file promises.
class ApkInfo {
  final String url;
  final String sha256; // lower-case hex, 64 characters
  final int sizeBytes;
  const ApkInfo(this.url, this.sha256, this.sizeBytes);
}

/// A message from you shown at the top of the app (see update.json "notices").
class AppNotice {
  final String id;
  final String text;
  final String textMl; // optional Malayalam text
  final String level; // info | warning | critical
  final DateTime? startsAt;
  final DateTime? expiresAt;
  final bool dismissible;
  final String linkUrl;
  final String linkLabel;
  const AppNotice({
    required this.id,
    required this.text,
    required this.textMl,
    required this.level,
    required this.startsAt,
    required this.expiresAt,
    required this.dismissible,
    required this.linkUrl,
    required this.linkLabel,
  });

  static DateTime? _date(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

  static AppNotice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = (raw['text'] as String?)?.trim() ?? '';
    final id = (raw['id'] as String?)?.trim() ?? '';
    if (text.isEmpty || id.isEmpty) return null;
    final level = (raw['level'] as String?) ?? 'info';
    return AppNotice(
      id: id,
      text: text,
      textMl: (raw['textMl'] as String?)?.trim() ?? '',
      level: const ['info', 'warning', 'critical'].contains(level) ? level : 'info',
      startsAt: _date(raw['startsAt']),
      expiresAt: _date(raw['expiresAt']),
      dismissible: raw['dismissible'] != false && level != 'critical',
      linkUrl: (raw['linkUrl'] as String?) ?? '',
      linkLabel: (raw['linkLabel'] as String?) ?? 'Learn more',
    );
  }

  bool activeAt(DateTime now) => (startsAt == null || !now.isBefore(startsAt!)) && (expiresAt == null || now.isBefore(expiresAt!));

  int get severity => level == 'critical' ? 2 : (level == 'warning' ? 1 : 0);
}

/// The contents of update/update.json, after its signature was checked.
class UpdateManifest {
  final String versionName;
  final int versionCode;
  final int minSupportedVersionCode;
  final bool forceUpdate;
  final String releaseDate;
  final String downloadUrl;
  final List<MirrorLink> mirrors;
  final double? sizeMb;
  final String message;
  final List<String> whatsNew;
  final List<String> improved;
  final List<String> fixed;
  final List<ReleaseNote> history;
  final int issuedAt;

  /// ABI name ("arm64-v8a" …) -> file. The key "universal" fits any phone.
  final Map<String, ApkInfo> apks;
  final List<AppNotice> notices;

  const UpdateManifest({
    required this.versionName,
    required this.versionCode,
    required this.minSupportedVersionCode,
    required this.forceUpdate,
    required this.releaseDate,
    required this.downloadUrl,
    required this.mirrors,
    required this.sizeMb,
    required this.message,
    required this.whatsNew,
    required this.improved,
    required this.fixed,
    required this.history,
    required this.issuedAt,
    required this.apks,
    required this.notices,
  });

  /// The file that fits this phone, or null if the update file offers no
  /// in-app download (the person is then sent to [downloadUrl]).
  ApkInfo? apkFor(List<String> deviceAbis) {
    for (final abi in deviceAbis) {
      final a = apks[abi];
      if (a != null) return a;
    }
    return apks['universal'];
  }

  static List<String> _strings(Object? v) => (v as List? ?? const []).map((e) => e.toString()).toList();

  static UpdateManifest fromJson(Map<String, dynamic> j) {
    return UpdateManifest(
      versionName: (j['versionName'] as String?) ?? '',
      versionCode: (j['versionCode'] as num).toInt(),
      minSupportedVersionCode: (j['minSupportedVersionCode'] as num?)?.toInt() ?? 1,
      forceUpdate: j['forceUpdate'] == true,
      releaseDate: (j['releaseDate'] as String?) ?? '',
      downloadUrl: (j['downloadUrl'] as String?) ?? '',
      mirrors: [
        for (final m in (j['alternateUrls'] as List? ?? const []))
          MirrorLink((m['label'] as String?) ?? 'Alternative link', (m['url'] as String?) ?? ''),
      ],
      sizeMb: (j['sizeMb'] as num?)?.toDouble(),
      message: (j['message'] as String?) ?? '',
      whatsNew: _strings(j['whatsNew']),
      improved: _strings(j['improved']),
      fixed: _strings(j['fixed']),
      history: [
        for (final h in (j['history'] as List? ?? const []))
          ReleaseNote((h['versionName'] as String?) ?? '', (h['releaseDate'] as String?) ?? '', _strings(h['notes'])),
      ],
      issuedAt: (j['issuedAt'] as num?)?.toInt() ?? 0,
      apks: {
        for (final e in ((j['apks'] as Map?) ?? const {}).entries)
          if (e.value is Map &&
              ((e.value as Map)['url'] as String?)?.startsWith('https://') == true &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(((e.value as Map)['sha256'] as String?) ?? ''))
            e.key.toString(): ApkInfo(
              (e.value as Map)['url'] as String,
              (e.value as Map)['sha256'] as String,
              ((e.value as Map)['sizeBytes'] as num?)?.toInt() ?? 0,
            ),
      },
      notices: [
        for (final n in (j['notices'] as List? ?? const []))
          if (AppNotice.fromJson(n) != null) AppNotice.fromJson(n)!,
      ],
    );
  }
}

enum UpdateStatus { none, optional, required }

enum UpdateCheckResult { upToDate, available, required, offline, notConfigured, invalid }

/// Feature: in-app updates, controlled from GitHub.
///
/// HOW IT WORKS
///  * You edit update/update.json in GitHub (new version number, release date,
///    "what's new", download links).
///  * A GitHub Action signs it with your private key and writes
///    update/update.signed.json.
///  * The app downloads that file, checks the signature against the public key
///    built into the app, and only believes it if the check passes. Nobody
///    else can make the app show a fake update.
///  * If the app's version is below "minSupportedVersionCode" the update is
///    REQUIRED: a full-screen page covers the app until the person updates.
///    If it's below "versionCode" the update is optional ("Later" is allowed).
///    "forceUpdate": true makes the newest version required too.
///
/// The last good file is kept on the phone, so a required update still blocks
/// the app when the phone is offline. An old signed file can't be replayed to
/// hide a newer one (each file carries a rising "issuedAt").
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final instance = UpdateService._();

  static const _storage = FlutterSecureStorage();
  static const _cacheKey = 'update_cache_v1';
  static const _highestKey = 'update_highest_issued_v1';

  UpdateManifest? manifest;
  UpdateStatus status = UpdateStatus.none;
  DateTime? lastChecked;
  bool checking = false;
  int _highestIssued = 0;
  Timer? _timer;

  int get currentCode => AppVersion.code;

  /// True when the app must not be used (update required, or a modified copy).
  static bool get blocked => instance.status == UpdateStatus.required || IntegrityService.instance.tampered;

  Future<void> init() async {
    unawaited(loadNotices());
    try {
      _highestIssued = int.tryParse(await _storage.read(key: _highestKey) ?? '') ?? 0;
      final cached = await _storage.read(key: _cacheKey);
      if (cached != null) {
        final m = await _verifyAndParse(cached);
        if (m != null) _apply(m);
      }
    } catch (e) {
      debugPrint('UpdateService.init: $e');
    }
    unawaited(check());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 3), (_) => check());
  }

  void dispose2() => _timer?.cancel();

  void _apply(UpdateManifest m) {
    manifest = m;
    final cur = currentCode;
    if (cur <= 0) {
      status = UpdateStatus.none; // couldn't read our own version — never block
    } else if (m.minSupportedVersionCode > cur || (m.forceUpdate && m.versionCode > cur)) {
      status = UpdateStatus.required;
    } else if (m.versionCode > cur) {
      status = UpdateStatus.optional;
    } else {
      status = UpdateStatus.none;
    }
    notifyListeners();
  }

  Future<UpdateManifest?> _verifyAndParse(String raw) async {
    try {
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      if (outer['alg'] != 'ed25519') return null;
      final payload = base64Decode(outer['payload'] as String);
      final sig = base64Decode(outer['sig'] as String);
      final algo = Ed25519();
      var ok = false;
      for (final k in updatePublicKeys()) {
        if (k.length != 32) continue;
        final good = await algo.verify(payload, signature: Signature(sig, publicKey: SimplePublicKey(k, type: KeyPairType.ed25519)));
        if (good) {
          ok = true;
          break;
        }
      }
      if (!ok) return null;
      final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final m = UpdateManifest.fromJson(json);
      if (m.versionCode < 1 || !m.downloadUrl.startsWith('https://')) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  /// Looks for an update now. Never throws.
  Future<UpdateCheckResult> check() async {
    if (checking) return UpdateCheckResult.offline;
    checking = true;
    notifyListeners();
    try {
      final uri = Uri.parse('$kUpdateManifestUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}');
      final res = await http.get(uri, headers: const {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 12));
      lastChecked = DateTime.now();
      if (res.statusCode == 404) return UpdateCheckResult.notConfigured;
      if (res.statusCode != 200) return UpdateCheckResult.offline;

      final m = await _verifyAndParse(utf8.decode(res.bodyBytes));
      if (m == null) {
        // Not trusted: ignore it (a wrong or half-copied file must never lock
        // honest users out) but leave a note for the crash log.
        debugPrint('UpdateService: update file failed signature check — ignored');
        return UpdateCheckResult.invalid;
      }
      if (m.issuedAt < _highestIssued) return UpdateCheckResult.invalid; // old file replayed
      _highestIssued = m.issuedAt;
      try {
        await _storage.write(key: _highestKey, value: '${m.issuedAt}');
        await _storage.write(key: _cacheKey, value: utf8.decode(res.bodyBytes));
      } catch (_) {}
      _apply(m);
      switch (status) {
        case UpdateStatus.required:
          return UpdateCheckResult.required;
        case UpdateStatus.optional:
          return UpdateCheckResult.available;
        case UpdateStatus.none:
          return UpdateCheckResult.upToDate;
      }
    } catch (_) {
      return UpdateCheckResult.offline;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  // ---- notices (remote banner) ----
  Set<String> _dismissedNotices = {};
  bool _noticesLoaded = false;

  Future<void> loadNotices() async {
    if (_noticesLoaded) return;
    _noticesLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _dismissedNotices = (prefs.getStringList('notices_dismissed_v1') ?? const <String>[]).toSet();
    } catch (_) {}
    notifyListeners();
  }

  /// The one notice to show right now (the most serious that is in its time
  /// window and wasn't dismissed), or null.
  AppNotice? get activeNotice {
    final list = manifest?.notices ?? const <AppNotice>[];
    final now = DateTime.now();
    AppNotice? best;
    for (final n in list) {
      if (!n.activeAt(now)) continue;
      if (n.dismissible && _dismissedNotices.contains(n.id)) continue;
      if (best == null || n.severity > best.severity) best = n;
    }
    return best;
  }

  Future<void> dismissNotice(String id) async {
    _dismissedNotices.add(id);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep the list from growing forever.
      final keep = _dismissedNotices.toList();
      await prefs.setStringList('notices_dismissed_v1', keep.length > 50 ? keep.sublist(keep.length - 50) : keep);
    } catch (_) {}
  }

  // ---- "later" memory for the optional prompt ----
  Future<bool> shouldPromptOptional() async {
    final m = manifest;
    if (m == null || status != UpdateStatus.optional) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getInt('update_prompt_code') ?? 0;
      final at = prefs.getInt('update_prompt_at') ?? 0;
      if (code == m.versionCode && DateTime.now().millisecondsSinceEpoch - at < const Duration(hours: 20).inMilliseconds) return false;
    } catch (_) {}
    return true;
  }

  Future<void> markPrompted() async {
    final m = manifest;
    if (m == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('update_prompt_code', m.versionCode);
      await prefs.setInt('update_prompt_at', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }
}
