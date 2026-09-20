import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'device_session_service.dart';
import 'message_relay_service.dart';

/// One message waiting to be sent later.
class ScheduledMessage {
  final String id;
  final String conversationId;
  final String peerUid;
  final String peerUsername;
  final String text;
  final DateTime sendAt;

  /// Send it without a notification on the recipient's phone.
  final bool silent;

  /// The chat's disappearing-message timer, captured when it was scheduled.
  final int ttlHours;
  final String? replyToId;

  /// 'pending' (will be sent) or 'failed' (needs the person's attention).
  final String status;
  final String? failReason;

  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
    required this.text,
    required this.sendAt,
    required this.silent,
    required this.ttlHours,
    this.replyToId,
    this.status = 'pending',
    this.failReason,
  });

  bool get isFailed => status == 'failed';

  ScheduledMessage copyWith({DateTime? sendAt, String? status, String? failReason, bool clearFailReason = false}) {
    return ScheduledMessage(
      id: id,
      conversationId: conversationId,
      peerUid: peerUid,
      peerUsername: peerUsername,
      text: text,
      sendAt: sendAt ?? this.sendAt,
      silent: silent,
      ttlHours: ttlHours,
      replyToId: replyToId,
      status: status ?? this.status,
      failReason: clearFailReason ? null : (failReason ?? this.failReason),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'peerUid': peerUid,
        'peerUsername': peerUsername,
        'text': text,
        'sendAt': sendAt.millisecondsSinceEpoch,
        'silent': silent,
        'ttlHours': ttlHours,
        'replyToId': replyToId,
        'status': status,
        'failReason': failReason,
      };

  factory ScheduledMessage.fromJson(Map<String, dynamic> j) => ScheduledMessage(
        id: j['id'] as String,
        conversationId: j['conversationId'] as String,
        peerUid: j['peerUid'] as String,
        peerUsername: (j['peerUsername'] as String?) ?? '',
        text: j['text'] as String,
        sendAt: DateTime.fromMillisecondsSinceEpoch((j['sendAt'] as num).toInt()),
        silent: j['silent'] == true,
        ttlHours: (j['ttlHours'] as num?)?.toInt() ?? 0,
        replyToId: j['replyToId'] as String?,
        status: (j['status'] as String?) ?? 'pending',
        failReason: j['failReason'] as String?,
      );
}

/// Feature: "Send later".
///
/// HOW IT WORKS — and its honest limit
///  * Messages are end-to-end encrypted ON THIS PHONE at the moment they're
///    sent, and the server never sees plaintext (by design). So a scheduled
///    message can't be handed to the server to send for you: it waits here,
///    on this phone, and THIS APP sends it when the time comes.
///  * That means the app has to be running at (or after) the due time. It
///    checks every 15 seconds while running, and again the moment the app is
///    opened. If a message came due while the app was closed:
///      - up to [autoSendGrace] late -> it's sent as soon as the app opens;
///      - later than that -> it is NOT sent automatically (a "good morning"
///        arriving at 4 PM is worse than useless). It's kept, marked
///        "Missed", and the person chooses: send it now, or delete it.
///  * The waiting messages are stored in the phone's encrypted secure storage,
///    tied to the signed-in account, and are wiped along with everything else
///    when a different account signs in.
class ScheduledMessageService {
  ScheduledMessageService._();
  static final instance = ScheduledMessageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _storageKey = 'scheduled_messages_v1';
  static const _uuid = Uuid();

  static const Duration checkEvery = Duration(seconds: 15);
  static const Duration autoSendGrace = Duration(hours: 2);

  /// What the UI listens to. Always the full list, oldest send time first.
  final ValueNotifier<List<ScheduledMessage>> items = ValueNotifier<List<ScheduledMessage>>(const []);

  Timer? _timer;
  bool _loaded = false;
  bool _ticking = false;
  List<ScheduledMessage> _list = [];

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ------------------------------------------------------------------
  // Lifecycle (started/stopped by main.dart with sign-in / sign-out)
  // ------------------------------------------------------------------

  Future<void> start() async {
    _timer?.cancel();
    await _ensureLoaded();
    _timer = Timer.periodic(checkEvery, (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _loaded = false;
    _list = [];
    items.value = const [];
  }

  // ------------------------------------------------------------------
  // Public actions
  // ------------------------------------------------------------------

  Future<ScheduledMessage> schedule({
    required String conversationId,
    required String peerUid,
    required String peerUsername,
    required String text,
    required DateTime sendAt,
    required bool silent,
    required int ttlHours,
    String? replyToId,
  }) async {
    await _ensureLoaded();
    final item = ScheduledMessage(
      id: _uuid.v4(),
      conversationId: conversationId,
      peerUid: peerUid,
      peerUsername: peerUsername,
      text: text,
      sendAt: sendAt,
      silent: silent,
      ttlHours: ttlHours,
      replyToId: replyToId,
    );
    _list.add(item);
    await _commit();
    return item;
  }

  Future<void> cancel(String id) async {
    await _ensureLoaded();
    _list.removeWhere((m) => m.id == id);
    await _commit();
  }

  /// "Send now" — also how a failed or missed message is retried.
  Future<void> sendNow(String id) async {
    await _ensureLoaded();
    final i = _list.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _list[i] = _list[i].copyWith(sendAt: DateTime.now(), status: 'pending', clearFailReason: true);
    await _commit();
    await tick(ignoreGrace: true);
  }

  /// Sends everything that has come due. Safe to call any time — it does
  /// nothing if a check is already running, nobody is signed in, or a login
  /// is still in progress on this phone.
  Future<void> tick({bool ignoreGrace = false}) async {
    if (_ticking) return;
    if (_uid == null) return;
    if (DeviceSessionService.instance.isClaimPending) return;
    _ticking = true;
    try {
      await _ensureLoaded();
      final now = DateTime.now();
      final due = _list.where((m) => !m.isFailed && !m.sendAt.isAfter(now)).toList()
        ..sort((a, b) => a.sendAt.compareTo(b.sendAt));

      for (final m in due) {
        if (_uid == null) break;
        final lateBy = now.difference(m.sendAt);
        if (!ignoreGrace && lateBy > autoSendGrace) {
          await _mark(m.id, failed: true, reason: 'Missed its time — the app was closed. Send it now, or delete it.');
          continue;
        }
        await _dispatch(m);
      }
    } finally {
      _ticking = false;
    }
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  Future<void> _dispatch(ScheduledMessage m) async {
    try {
      await MessageRelayService.sendMessage(
        conversationId: m.conversationId,
        recipientUid: m.peerUid,
        text: m.text,
        replyToId: m.replyToId,
        ttlHours: m.ttlHours,
        silent: m.silent,
      );
      _list.removeWhere((x) => x.id == m.id);
      await _commit();
    } on IdentityChangedException catch (_) {
      // Never auto-trust a changed security code on somebody's behalf.
      await _mark(
        m.id,
        failed: true,
        reason: "${m.peerUsername.isEmpty ? 'This contact' : m.peerUsername}'s security code changed. "
            'Open the chat to review it, then send this again.',
      );
    } on BlockedException catch (e) {
      await _mark(m.id, failed: true, reason: e.message);
    } on ChatFrozenException catch (e) {
      await _mark(m.id, failed: true, reason: e.message);
    } on RateLimitedException catch (_) {
      // Too many messages just now — leave it pending; the next check retries.
    } on NotSignedInException catch (_) {
      // Signed out mid-way — leave it; nothing to do until sign-in.
    } catch (e) {
      final text = e.toString();
      if (text.contains('0006_silent_messages')) {
        await _mark(m.id, failed: true, reason: "Silent send isn't set up on the server yet.");
      } else {
        // Most likely no connection — leave it pending and try again shortly.
        debugPrint('ScheduledMessageService: could not send ${m.id} yet: $e');
      }
    }
  }

  Future<void> _mark(String id, {required bool failed, String? reason}) async {
    final i = _list.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _list[i] = _list[i].copyWith(status: failed ? 'failed' : 'pending', failReason: reason);
    await _commit();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final uid = _uid;
    _list = [];
    if (uid != null) {
      try {
        final raw = await _storage.read(key: _storageKey);
        if (raw != null) {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          if (data['owner'] == uid) {
            _list = (data['items'] as List<dynamic>)
                .map((e) => ScheduledMessage.fromJson(e as Map<String, dynamic>))
                .toList();
          } else {
            // Left over from a different account — never send or show it.
            await _storage.delete(key: _storageKey);
          }
        }
      } catch (_) {
        _list = [];
      }
    }
    _loaded = true;
    _publish();
  }

  Future<void> _commit() async {
    _publish();
    final uid = _uid;
    if (uid == null) return;
    try {
      if (_list.isEmpty) {
        await _storage.delete(key: _storageKey);
      } else {
        await _storage.write(
          key: _storageKey,
          value: jsonEncode({'owner': uid, 'items': _list.map((m) => m.toJson()).toList()}),
        );
      }
    } catch (e) {
      debugPrint('ScheduledMessageService: could not save: $e');
    }
  }

  void _publish() {
    final sorted = List<ScheduledMessage>.from(_list)..sort((a, b) => a.sendAt.compareTo(b.sendAt));
    items.value = sorted;
  }
}
