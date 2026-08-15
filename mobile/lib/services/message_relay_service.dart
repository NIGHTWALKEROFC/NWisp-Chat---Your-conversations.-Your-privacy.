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

/// Moves message content through Supabase as a pure, temporary relay:
/// insert -> the recipient's device picks it up over Realtime (or on
/// reconnect) -> decrypts -> saves locally -> deletes the row. Nothing about
/// message content is meant to sit in the `message_relay` table for long.
class MessageRelayService {
  static final _client = Supabase.instance.client;
  static final _db = FirebaseFirestore.instance;
  static final _uuid = Uuid();
  static final Map<String, String> _publicKeyCache = {};
  static RealtimeChannel? _channel;

  static String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  static Future<String> _publicKeyFor(String uid) async {
    if (_publicKeyCache.containsKey(uid)) return _publicKeyCache[uid]!;
    final doc = await _db.collection('users').doc(uid).get();
    final key = doc.data()?['publicKey'] as String?;
    if (key == null) throw Exception('That user has not set up encryption keys yet.');
    _publicKeyCache[uid] = key;
    return key;
  }

  /// Call once after sign-in (see main.dart / auth_gate.dart). Subscribes to
  /// incoming rows and also catches up on anything that arrived while the
  /// app was closed.
  static Future<void> start() async {
    await _catchUp();
    _channel?.unsubscribe();
    _channel = _client
        .channel('message_relay_inbox_$_myUid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_relay',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'recipient_uid', value: _myUid),
          callback: (payload) => _handleRow(payload.newRecord),
        )
        .subscribe();
  }

  static void stop() {
    _channel?.unsubscribe();
    _channel = null;
  }

  static Future<void> _catchUp() async {
    final rows = await _client.from('message_relay').select().eq('recipient_uid', _myUid);
    for (final row in rows) {
      await _handleRow(row);
    }
  }

  static Future<void> _handleRow(Map<String, dynamic> row) async {
    try {
      final senderUid = row['sender_uid'] as String;
      final senderPublicKey = await _publicKeyFor(senderUid);
      final payload = await CryptoService.decryptFromPeer(
        ciphertextB64: row['ciphertext'] as String,
        nonceB64: row['nonce'] as String,
        senderPublicKeyB64: senderPublicKey,
      );
      final messageType = row['message_type'] as String;

      if (messageType == 'receipt') {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.setStatus(data['ref'] as String, data['status'] as String);
      } else if (messageType == 'delete') {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.deleteMessage(data['ref'] as String);
      } else if (messageType == 'clear') {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.clearConversation(data['conversationId'] as String);
      } else {
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
        await _sendReceipt(conversationId: row['conversation_id'] as String, toUid: senderUid, ref: row['client_id'] as String, status: 'delivered');
      }
    } finally {
      await _client.from('message_relay').delete().eq('id', row['id']);
    }
  }

  static Future<void> _checkNotBlocked(String recipientUid) async {
    final doc = await _db.collection('users').doc(recipientUid).get();
    final blockedByThem = List<String>.from(doc.data()?['blockedUsers'] ?? []);
    if (blockedByThem.contains(_myUid)) {
      throw BlockedException("You can't message this user.");
    }
  }

  static Future<String> sendMessage({
    required String conversationId,
    required String recipientUid,
    required String text,
    String messageType = 'text',
    String? mediaPath,
    String? replyToId,
    required int ttlHours,
  }) async {
    await _checkNotBlocked(recipientUid);
    final clientId = _uuid.v4();
    final recipientKey = await _publicKeyFor(recipientUid);
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

  /// "Clear chat" — same idea, tells the peer's device to wipe it locally too.
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
