import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_message_store.dart';
import 'message_relay_service.dart';

/// When a received photo / video / voice message may be downloaded.
enum DownloadRule {
  /// Always (Wi-Fi or mobile data).
  always,

  /// Only while on Wi-Fi.
  wifiOnly,

  /// Never by itself — tap the message to download.
  never,
}

/// Feature: auto-download rules.
///
/// For each kind of media you choose: always, Wi-Fi only, or never. A message
/// that isn't allowed to download right now shows a "Tap to download" tile.
/// Messages waiting for Wi-Fi download by themselves as soon as Wi-Fi is back.
class AutoDownloadService {
  AutoDownloadService._();
  static final instance = AutoDownloadService._();

  static const kinds = ['image', 'video', 'voice'];

  static const _defaults = {
    'image': DownloadRule.always,
    'video': DownloadRule.wifiOnly,
    'voice': DownloadRule.always,
  };

  /// Rules in memory so the receive path doesn't wait on disk every message.
  final Map<String, DownloadRule> _rules = Map.of(_defaults);
  bool _loaded = false;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _draining = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in kinds) {
        final v = prefs.getString('autodl_$k');
        if (v != null) {
          _rules[k] = DownloadRule.values.firstWhere((r) => r.name == v, orElse: () => _defaults[k]!);
        }
      }
    } catch (e) {
      debugPrint('AutoDownloadService.load: $e');
    }
    _loaded = true;
  }

  DownloadRule ruleFor(String kind) => _rules[kind] ?? DownloadRule.always;

  Future<void> setRule(String kind, DownloadRule rule) async {
    _rules[kind] = rule;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('autodl_$kind', rule.name);
    if (rule != DownloadRule.never) unawaited(drainPending());
  }

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      // If we can't tell, don't block a download the person expects.
      return true;
    }
  }

  /// Should this kind of media be fetched right now?
  Future<bool> allowedNow(String kind) async {
    await load();
    switch (ruleFor(kind)) {
      case DownloadRule.always:
        return true;
      case DownloadRule.never:
        return false;
      case DownloadRule.wifiOnly:
        return _onWifi();
    }
  }

  /// Starts listening for network changes (call once after sign-in).
  void start() {
    _sub?.cancel();
    _sub = Connectivity().onConnectivityChanged.listen((_) => drainPending());
    unawaited(drainPending());
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// Downloads everything that was waiting and is allowed now.
  Future<void> drainPending() async {
    if (_draining) return;
    _draining = true;
    try {
      await load();
      final pending = await LocalMessageStore.pendingDownloads();
      for (final p in pending) {
        if (ruleFor(p.type) == DownloadRule.never) continue;
        if (!await allowedNow(p.type)) continue;
        try {
          await MessageRelayService.downloadPendingMedia(p.id);
        } catch (_) {
          // Expired on the server or a network blip — the tile stays so the
          // person can try again by hand.
        }
      }
    } finally {
      _draining = false;
    }
  }
}

class PendingDownload {
  final String id;
  final String type;
  const PendingDownload(this.id, this.type);
}
