import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'crypto_service.dart';
import 'local_message_store.dart';

class BlockedException implements Exception {
  final String message;
  BlockedException(this.message);
  @override
  String toString() => message;
}

class NotSignedInException implements Exception {
  final String message = "You're not signed in. Please sign in again.";
  @override
  String toString() => message;
}

/// Moves message content through Supabase as a pure, temporary relay:
/// insert -> the recipient's device picks it up over Realtime (or on
/// reconnect) -> decrypts -> saves locally -> deletes the row. Nothing about
/// message content is meant to sit in the `message_relay` table for long.
class MessageRelayService {
  static final _client = Supabase.instance.client;
  static final _db = FirebaseFirestore.instance;
  static final _uuid = const Uuid();

  /// Public keys are cached briefly (not forever, not never) — long enough
  /// to avoid a Firestore read on every keystroke-adjacent action, short
  /// enough that a contact who rotated their identity key pair (reinstall,
  /// switching accounts on a device — see SessionService) is picked up
  /// again within a few minutes even without any explicit invalidation.
  static final Map<String, _CachedKey> _publicKeyCache = {};
  static const _keyCacheTtl = Duration(minutes: 3);

  static RealtimeChannel? _channel;
  static Timer? _reconnectTimer;

  /// A safe accessor instead of a bare `!` null-check — a null session here
  /// (e.g. an expired/revoked token) now surfaces as a clear, catchable
  /// NotSignedInException instead of an unhandled null-check crash.
  static String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw NotSignedInException();
    return uid;
  }

  static Future<String> _publicKeyFor(String uid, {bool forceRefresh = false}) async {
    final cached = _publicKeyCache[uid];
    if (!forceRefresh && cached != null && DateTime.now().difference(cached.fetchedAt) < _keyCacheTtl) {
      return cached.key;
    }
    final doc = await _db.collection('users').doc(uid).get();
    final key = doc.data()?['publicKey'] as String?;
    if (key == null) throw Exception('That user has not set up encryption keys yet.');
    _publicKeyCache[uid] = _CachedKey(key, DateTime.now());
    return key;
  }

  /// Clears every cached public key on this device — used when a different
  /// account signs in (see SessionService), and safe to call any other
  /// time too since keys just get refetched on demand afterward.
  static void resetPublicKeyCache() => _publicKeyCache.clear();

  /// Call once after sign-in (see main.dart). Subscribes to incoming rows
  /// and also catches up on anything that arrived while the app was closed.
  static Future<void> start() async {
    try {
      await _catchUp();
    } catch (_) {
      // Don't let a catch-up failure (e.g. no network right this instant)
      // stop us from subscribing to live updates below — we'll catch up
      // again on the next reconnect/app start regardless.
    }
    _subscribe();
  }

  static void _subscribe() {
    _channel?.unsubscribe();
    final myUid = _myUid;
    _channel = _client
        .channel('message_relay_inbox_$myUid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_relay',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'recipient_uid', value: myUid),
          callback: (payload) {
            _handleRow(payload.newRecord).catchError((_) {
              // Leave it in the relay table — it'll be retried on the next
              // catch-up instead of being silently lost.
            });
          },
        )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        _reconnectTimer?.cancel();
        // A gap in the realtime connection (however brief) could have
        // meant a missed insert — sweep for anything still sitting in the
        // relay table for us.
        _catchUp().catchError((_) {});
        return;
      }
      if (status == RealtimeSubscribeStatus.channelError || status == RealtimeSubscribeStatus.closed) {
        // Don't just go quiet — retry the subscription instead of leaving
        // this device permanently unable to receive messages until it's
        // manually restarted.
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 4), () {
          if (FirebaseAuth.instance.currentUser != null) _subscribe();
        });
      }
    });
  }

  static void stop() {
    _reconnectTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
  }

  static Future<void> _catchUp() async {
    final rows = await _client.from('message_relay').select().eq('recipient_uid', _myUid);
    for (final row in rows) {
      try {
        await _handleRow(row);
      } catch (_) {
        // Leave this one for the next catch-up rather than letting one bad
        // row block the rest of the inbox from being processed.
      }
    }
  }

  static Future<String> _decryptRow(Map<String, dynamic> row, String senderUid) async {
    try {
      final key = await _publicKeyFor(senderUid);
      return await CryptoService.decryptFromPeer(
        ciphertextB64: row['ciphertext'] as String,
        nonceB64: row['nonce'] as String,
        senderPublicKeyB64: key,
      );
    } catch (_) {
      // The sender may have rotated their identity key pair since we
      // cached it (reinstall, or an account switch on their device).
      // Refetch once, live, before giving up.
      final freshKey = await _publicKeyFor(senderUid, forceRefresh: true);
      return await CryptoService.decryptFromPeer(
        ciphertextB64: row['ciphertext'] as String,
        nonceB64: row['nonce'] as String,
        senderPublicKeyB64: freshKey,
      );
    }
  }

  /// Processes one relay row. The row is only deleted from `message_relay`
  /// AFTER it's been fully and successfully handled — if anything here
  /// throws (bad decrypt, a dropped network call), the row is left in
  /// place so it's retried on the next catch-up instead of being silently
  /// and permanently lost.
  static Future<void> _handleRow(Map<String, dynamic> row) async {
    final senderUid = row['sender_uid'] as String;
    final messageType = row['message_type'] as String;
    final payload = await _decryptRow(row, senderUid);

    switch (messageType) {
      case 'receipt':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.setStatus(data['ref'] as String, data['status'] as String);
        break;
      case 'delete':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.deleteMessage(data['ref'] as String);
        break;
      case 'clear':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.clearConversation(data['conversationId'] as String);
        break;
      case 'reaction':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.setReaction(data['ref'] as String, senderUid, data['emoji'] as String?);
        break;
      default:
        final ttlHours = (row['ttl_hours'] as num?)?.toInt() ?? 24;
        final createdAt = DateTime.now();
        await LocalMessageStore.insert(
          id: row['client_id'] as String,
          conversationId: row['conversation_id'] as String,
          peerUid: senderUid,
          senderUid: senderUid,
          isMine: false,
          text: payload,
          messageType: messageType,
          mediaPath: row['media_path'] as String?,
          replyToId: row['reply_to_id'] as String?,
          status: 'delivered',
          createdAt: createdAt,
          expiresAt: createdAt.add(Duration(hours: ttlHours)),
        );
        await _sendReceipt(
          conversationId: row['conversation_id'] as String,
          toUid: senderUid,
          ref: row['client_id'] as String,
          status: 'delivered',
        );
    }

    await _client.from('message_relay').delete().eq('id', row['id']);
  }

  /// Reads the narrow blocks/{recipientUid}_{myUid} lookup doc (see
  /// firestore.rules + ModerationService) rather than the recipient's full
  /// blockedUsers list — that list is private to them now, and this is a
  /// targeted "did THEY block ME specifically" check, not a way to see
  /// anyone's whole block list.
  static Future<void> _checkNotBlocked(String recipientUid) async {
    final doc = await _db.collection('blocks').doc('${recipientUid}_$_myUid').get();
    if (doc.exists) {
      throw BlockedException("You can't message this user.");
    }
  }

  /// Sends a message. Every step that can fail (auth, blocking, missing
  /// recipient keys, the network insert) happens BEFORE anything is written
  /// to the local message store — so a failed send never shows up as a
  /// message in the chat.
  static Future<String> sendMessage({
    required String conversationId,
    required String recipientUid,
    required String text,
    String messageType = 'text',
    String? mediaPath,
    String? replyToId,
    required int ttlHours,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();

    await _checkNotBlocked(recipientUid);
    final clientId = _uuid.v4();
    // Always fetch a live public key for sends specifically — if we
    // silently encrypted with a stale cached key here, the recipient would
    // never be able to decrypt it and we'd have no way to know the send
    // "failed", since the Supabase insert itself always succeeds.
    final recipientKey = await _publicKeyFor(recipientUid, forceRefresh: true);
    final (ciphertext, nonce) = await CryptoService.encryptForPeer(text, recipientKey);

    await _client.from('message_relay').insert({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': recipientUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': messageType,
      'media_path': mediaPath,
      'reply_to_id': replyToId,
      'client_id': clientId,
      'ttl_hours': ttlHours,
    });

    final createdAt = DateTime.now();
    await LocalMessageStore.insert(
      id: clientId,
      conversationId: conversationId,
      peerUid: recipientUid,
      senderUid: _myUid,
      isMine: true,
      text: text,
      messageType: messageType,
      mediaPath: mediaPath,
      replyToId: replyToId,
      status: 'sent',
      createdAt: createdAt,
      expiresAt: createdAt.add(Duration(hours: ttlHours)),
    );
    return clientId;
  }

  static Future<void> _sendReceipt({
    required String conversationId,
    required String toUid,
    required String ref,
    required String status,
  }) async {
    final key = await _publicKeyFor(toUid);
    final (ciphertext, nonce) = await CryptoService.encryptForPeer(jsonEncode({'ref': ref, 'status': status}), key);
    await _client.from('message_relay').insert({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'receipt',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
  }

  static Future<void> sendReadReceipt({required String conversationId, required String toUid, required String ref}) {
    return _sendReceipt(conversationId: conversationId, toUid: toUid, ref: ref, status: 'read');
  }

  static Future<void> sendReaction({
    required String conversationId,
    required String toUid,
    required String messageId,
    required String? emoji,
  }) async {
    final key = await _publicKeyFor(toUid);
    final (ciphertext, nonce) = await CryptoService.encryptForPeer(jsonEncode({'ref': messageId, 'emoji': emoji}), key);
    await _client.from('message_relay').insert({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'reaction',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
  }

  /// Telegram-style "delete for everyone": removes it from our own device
  /// AND tells the peer's device to remove it from theirs. Nothing to
  /// un-send server-side because nothing stays server-side.
  static Future<void> deleteForEveryone({required String conversationId, required String toUid, required String messageId}) async {
    final key = await _publicKeyFor(toUid);
    final (ciphertext, nonce) = await CryptoService.encryptForPeer(jsonEncode({'ref': messageId}), key);
    await _client.from('message_relay').insert({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'delete',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
    await LocalMessageStore.deleteMessage(messageId);
  }

  static Future<void> deleteForMe(String messageId) => LocalMessageStore.deleteMessage(messageId);

  /// "Clear chat" — tells the peer's device to wipe it locally too.
  static Future<void> clearForBoth({required String conversationId, required String toUid}) async {
    final key = await _publicKeyFor(toUid);
    final (ciphertext, nonce) = await CryptoService.encryptForPeer(jsonEncode({'conversationId': conversationId}), key);
    await _client.from('message_relay').insert({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'clear',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
    await LocalMessageStore.clearConversation(conversationId);
  }
}

class _CachedKey {
  final String key;
  final DateTime fetchedAt;
  _CachedKey(this.key, this.fetchedAt);
}
