import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'integrity_service.dart';
import 'update_service.dart';

enum InstallPhase {
  /// Nothing started.
  idle,

  /// The file is coming down.
  downloading,

  /// Checking the file is exactly the one you published.
  verifying,

  /// Android needs the person's OK to install apps from NWisp.
  needPermission,

  /// Checked and ready — the installer opens (or "Install now" opens it again).
  ready,

  /// Something went wrong; see [UpdateInstaller.error].
  error,
}

/// Feature: download the update inside the app and install it.
///
///  1. Picks the file that fits this phone from the signed update file.
///  2. Downloads it with a progress bar into NWisp's private folder.
///  3. Checks it:
///       * its SHA-256 must equal the one in the SIGNED update file — so a
///         swapped, corrupted or hijacked download is deleted, never installed;
///       * it must be NWisp (same package name), newer than this version, and
///         signed with the same key as the installed app (otherwise Android
///         would refuse it anyway — we say so in plain words first).
///  4. Opens Android's own installer. Android always asks the person to confirm
///     — an app can't install silently.
class UpdateInstaller extends ChangeNotifier with WidgetsBindingObserver {
  UpdateInstaller._();
  static final instance = UpdateInstaller._();

  static const _channel = MethodChannel('com.nightwalker.securechat/updater');
  static const _ourPackage = 'com.nightwalker.securechat';

  InstallPhase phase = InstallPhase.idle;
  double? progress; // 0..1, null when the size is unknown
  int receivedBytes = 0;
  int totalBytes = 0;
  String error = '';

  /// True when the failure means "send them to the browser link instead".
  bool offerBrowserFallback = false;

  bool _cancel = false;
  String? _readyPath;
  bool _observing = false;

  bool get busy => phase == InstallPhase.downloading || phase == InstallPhase.verifying;

  /// Does this update offer an in-app download for this phone?
  Future<bool> canDownloadInApp(UpdateManifest m) async => m.apkFor(await _abis()) != null;

  Future<List<String>> _abis() async {
    try {
      return List<String>.from(await _channel.invokeListMethod<String>('abis') ?? const []);
    } catch (_) {
      return const [];
    }
  }

  void _set(InstallPhase p, {String err = '', bool fallback = false}) {
    phase = p;
    error = err;
    offerBrowserFallback = fallback;
    notifyListeners();
  }

  void cancel() => _cancel = true;

  void reset() {
    if (busy) return;
    _set(InstallPhase.idle);
  }

  /// Download, check, install.
  Future<void> start(UpdateManifest m) async {
    if (busy) return;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _cancel = false;
    progress = 0;
    receivedBytes = 0;
    totalBytes = 0;
    _readyPath = null;

    final apk = m.apkFor(await _abis());
    if (apk == null) {
      _set(InstallPhase.error, err: "This update has no direct download for your phone. Use the browser link instead.", fallback: true);
      return;
    }
    if (!apk.url.startsWith('https://')) {
      _set(InstallPhase.error, err: 'The download link is not secure, so it was not used.', fallback: true);
      return;
    }

    String dirPath;
    try {
      dirPath = (await _channel.invokeMethod<String>('updateDir'))!;
      // Old update files from earlier tries are not needed.
      await _channel.invokeMethod('cleanUpdates');
    } catch (e) {
      _set(InstallPhase.error, err: "Couldn't prepare space for the update.", fallback: true);
      return;
    }
    final file = File('$dirPath/nwisp-${m.versionCode}.apk');

    // ---- 1. download ----
    _set(InstallPhase.downloading);
    totalBytes = apk.sizeBytes;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(apk.url));
      final res = await client.send(req).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) {
        _set(InstallPhase.error, err: 'The download server answered with error ${res.statusCode}.', fallback: true);
        return;
      }
      final len = res.contentLength;
      if (len != null && len > 0) totalBytes = len;
      final sink = file.openWrite();
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 40))) {
          if (_cancel) break;
          sink.add(chunk);
          receivedBytes += chunk.length;
          progress = totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      if (_cancel) {
        await _delete(file);
        _set(InstallPhase.idle);
        return;
      }
    } on TimeoutException {
      await _delete(file);
      _set(InstallPhase.error, err: 'The download stalled. Check your connection and try again.', fallback: true);
      return;
    } catch (e) {
      await _delete(file);
      _set(InstallPhase.error, err: "Couldn't download the update. Check your connection and try again.", fallback: true);
      return;
    } finally {
      client.close();
    }

    // ---- 2. check ----
    _set(InstallPhase.verifying);
    progress = null;
    try {
      final sha = await _channel.invokeMethod<String>('sha256File', {'path': file.path});
      if (sha == null || sha.toLowerCase() != apk.sha256) {
        await _delete(file);
        _set(InstallPhase.error, err: "The downloaded file doesn't match the checksum you published, so it was deleted and NOT installed. The download link may have been changed.");
        return;
      }
      final info = await _channel.invokeMapMethod<String, dynamic>('inspectApk', {'path': file.path});
      if (info == null || info['error'] != null) {
        await _delete(file);
        _set(InstallPhase.error, err: 'The downloaded file is not a valid app file, so it was deleted.');
        return;
      }
      if (info['packageName'] != _ourPackage) {
        await _delete(file);
        _set(InstallPhase.error, err: "The downloaded file is a different app, so it was deleted.");
        return;
      }
      final newCode = (info['versionCode'] as num?)?.toInt() ?? 0;
      if (newCode <= UpdateService.instance.currentCode) {
        await _delete(file);
        _set(InstallPhase.error, err: 'The downloaded file is not newer than the app you have, so it was not installed.');
        return;
      }
      final installed = IntegrityService.instance.info?.certs ?? const <String>[];
      final fresh = List<String>.from(info['certs'] as List? ?? const []);
      if (installed.isNotEmpty && fresh.isNotEmpty && !fresh.any(installed.contains)) {
        await _delete(file);
        _set(InstallPhase.error,
            err: 'This update is signed with a different key than the app you have, so Android would refuse to install it over your chats. '
                'Build every version with the same signing key (see the update guide).');
        return;
      }
    } catch (e) {
      await _delete(file);
      _set(InstallPhase.error, err: "Couldn't check the downloaded file, so it was not installed.");
      return;
    }

    _readyPath = file.path;
    await install();
  }

  /// Opens Android's installer for the checked file.
  Future<void> install() async {
    final path = _readyPath;
    if (path == null || !await File(path).exists()) {
      _set(InstallPhase.error, err: 'The update file is gone. Please start the update again.');
      return;
    }
    try {
      final can = await _channel.invokeMethod<bool>('canInstall') ?? true;
      if (!can) {
        _set(InstallPhase.needPermission);
        return;
      }
      await _channel.invokeMethod('installApk', {'path': path});
      _set(InstallPhase.ready);
    } catch (e) {
      _set(InstallPhase.error, err: "Couldn't open the installer. Open the downloaded file from your Downloads instead, or use the browser link.", fallback: true);
    }
  }

  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the "install unknown apps" settings page → carry on.
    if (state == AppLifecycleState.resumed && phase == InstallPhase.needPermission) install();
  }

  Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
