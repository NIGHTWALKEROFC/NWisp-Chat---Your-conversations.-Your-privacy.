import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'crypto_service.dart';
import 'local_media_files.dart';
import 'local_message_store.dart';
import 'media_service.dart';
import 'message_relay_service.dart' show NotSignedInException;
import 'signal_session_service.dart';
export 'signal_store.dart' show IdentityChangedException;

/// One member a group message couldn't be delivered to, and why. Carried
/// by [GroupSendPartialFailure] so the UI can tell the sender exactly who
/// was missed instead of a generic "something went wrong."
class GroupMemberSendFailure {
  final String uid;
  final Object error;
  GroupMemberSendFailure(this.uid, this.error);
}

/// Thrown when a group message was saved locally and reached AT LEAST ONE
/// member, but not all of them (e.g. one member's Double Ratchet session
/// couldn't be re-established this send). Deliberately NOT the same as a
/// total failure: unlike 1:1 MessageRelayService.sendMessage (which never
/// touches local storage on failure), a partially-sent group message is
/// still real and already showing in the chat — callers should warn, not
/// roll it back.
class GroupSendPartialFailure implements Exception {
  final String clientId;
  final List<GroupMemberSendFailure> failures;
  GroupSendPartialFailure(this.clientId, this.failures);
  @override
  String toString() => 'Delivered to some members, but not: ${failures.map((f) => f.uid).join(', ')}';
}

/// Group-chat counterpart to MessageRelayService (Phase 5's 1:1 relay).
/// Deliberately does NOT introduce a new group-ratchet / "Sender Keys"
/// crypto primitive: per the Phase 7 dependency note, it fans a group
/// message out as one individually Double-Ratchet-encrypted copy per
/// OTHER member, reusing SignalSessionService.encryptForPeer exactly like
/// a 1:1 message. Because DeviceSessionService enforces a single active
/// device per account (see its own doc comment — this app never grew real
/// Signal-style *simultaneous* multi-device fan-out, and
/// SignalSessionService hardcodes deviceId=1), that's exactly one
/// ciphertext copy per member, not per member-device.
///
/// The RECEIVE side needs no group-specific code at all: an incoming row
/// already carries `sender_uid` and `conversation_id` regardless of
/// whether it came from a 1:1 send or a group fan-out, and
/// MessageRelayService's existing realtime subscription + `_handleRow`
/// already decrypt, store, and react to it generically. The one exception
/// — group media isn't deleted from Storage after the first member
/// downloads it, since every member needs the same blob — is handled by a
/// small guard in MessageRelayService._receiveMediaMessage.
///
/// Known v1 limitation, flagged rather than silently shipped: read/
/// delivered receipts for group messages are approximate. Each member's
/// device sends a 'delivered'/'read' receipt back to the ORIGINAL sender
/// the same way 1:1 chat already does (unchanged, generic code in
/// MessageRelayService._handleRow), but LocalMessageStore only has one
/// `status` column per message row, not one per recipient — so the
/// sender's UI shows whichever status the LAST-arriving receipt set, not
/// a true "3 of 5 read" breakdown. Doing that properly needs a normalized
/// per-recipient status table, which is a bigger schema change than this
/// pass makes.
class GroupMessageRelayService {
  static final _client = Supabase.instance.client;
  static final _uuid = const Uuid();

  static const _mediaBucket = 'media'; // same bucket 1:1 chat + stories use

  static String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw NotSignedInException();
    return uid;
  }

  static DateTime? _expiryFor(DateTime createdAt, int ttlHours) {
    if (ttlHours <= 0) return null;
    return createdAt.add(Duration(hours: ttlHours));
  }

  /// Sends a text message to every uid in [memberUids] (pass every OTHER
  /// current member — GroupChatScreen gets that list live from
  /// GroupService/Firestore; this method itself also filters out the
  /// caller's own uid defensively). Every fanned-out copy shares the same
  /// [clientId] so a later reaction/receipt/delete referencing that id
  /// applies to the one group message everyone sees, not N separate ones.
  static Future<String> sendGroupMessage({
    required String groupId,
    required List<String> memberUids,
    required String text,
    String messageType = 'text',
    String? replyToId,
    required int ttlHours,
  }) async {
    final myUid = _myUid;
    final clientId = _uuid.v4();
    final others = memberUids.where((u) => u != myUid).toSet().toList();
    final failures = <GroupMemberSendFailure>[];

    for (final uid in others) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, text);
        await _client.from('message_relay').insert({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': messageType,
          'reply_to_id': replyToId,
          'client_id': clientId,
          'ttl_hours': ttlHours,
        });
      } catch (e) {
        failures.add(GroupMemberSendFailure(uid, e));
      }
    }

    final createdAt = DateTime.now();
    await LocalMessageStore.insert(
      id: clientId,
      conversationId: groupId,
      peerUid: myUid, // group rows: peer_uid always == sender_uid, see LocalMessageStore
      senderUid: myUid,
      isMine: true,
      text: text,
      messageType: messageType,
      replyToId: replyToId,
      status: 'sent',
      createdAt: createdAt,
      expiresAt: _expiryFor(createdAt, ttlHours),
    );

    if (failures.isNotEmpty) throw GroupSendPartialFailure(clientId, failures);
    return clientId;
  }

  /// Group counterpart to MessageRelayService.sendMediaMessage. The
  /// encrypted file is uploaded to Supabase Storage exactly ONCE and
  /// shared by every member — only the small per-member JSON blob (the
  /// random file key + nonce) is individually Double-Ratchet-encrypted N
  /// times, the same trade-off Signal's own groups make.
  static Future<String> sendGroupMediaMessage({
    required String groupId,
    required List<String> memberUids,
    required List<int> plainBytes,
    required String messageType, // 'image' | 'video' | 'voice'
    required String extension,
    required String mime,
    String? caption,
    int? durationMs,
    required int ttlHours,
  }) async {
    final myUid = _myUid;
    final clientId = _uuid.v4();
    final others = memberUids.where((u) => u != myUid).toSet().toList();

    final fileKey = await CryptoService.generateFileKey();
    final (encryptedBytes, fileNonce) = await CryptoService.encryptFileBytes(plainBytes, fileKey);
    final remotePath = 'chat_media/$myUid/${_uuid.v4()}.enc';
    await MediaService.uploadBytes(Uint8List.fromList(encryptedBytes), _mediaBucket, remotePath);

    final metaPayload = jsonEncode({
      'fileKey': fileKey,
      'nonce': fileNonce,
      'mime': mime,
      'extension': extension,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      if (durationMs != null) 'durationMs': durationMs,
    });

    final failures = <GroupMemberSendFailure>[];
    for (final uid in others) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, metaPayload);
        await _client.from('message_relay').insert({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': messageType,
          'media_path': remotePath,
          'client_id': clientId,
          'ttl_hours': ttlHours,
        });
      } catch (e) {
        failures.add(GroupMemberSendFailure(uid, e));
      }
    }

    final localPath = await LocalMediaFiles.save(Uint8List.fromList(plainBytes), extension);
    final createdAt = DateTime.now();
    await LocalMessageStore.insert(
      id: clientId,
      conversationId: groupId,
      peerUid: myUid,
      senderUid: myUid,
      isMine: true,
      text: caption ?? '',
      messageType: messageType,
      mediaPath: localPath,
      status: 'sent',
      createdAt: createdAt,
      expiresAt: _expiryFor(createdAt, ttlHours),
    );

    if (failures.isNotEmpty) throw GroupSendPartialFailure(clientId, failures);
    return clientId;
  }

  /// Fans a reaction out to every other member — best-effort, same as 1:1:
  /// a reaction that doesn't reach one member isn't worth blocking or
  /// retrying like a real message send.
  static Future<void> sendReaction({
    required String groupId,
    required List<String> memberUids,
    required String messageId,
    required String? emoji,
  }) async {
    final myUid = _myUid;
    for (final uid in memberUids.where((u) => u != myUid)) {
      try {
        final (ciphertext, nonce) =
            await SignalSessionService.instance.encryptForPeer(uid, jsonEncode({'ref': messageId, 'emoji': emoji}));
        await _client.from('message_relay').insert({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': 'reaction',
          'client_id': _uuid.v4(),
          'ttl_hours': 1,
        });
      } catch (_) {}
    }
  }

  static Future<void> deleteForEveryone({
    required String groupId,
    required List<String> memberUids,
    required String messageId,
  }) async {
    final myUid = _myUid;
    for (final uid in memberUids.where((u) => u != myUid)) {
      try {
        final (ciphertext, nonce) =
            await SignalSessionService.instance.encryptForPeer(uid, jsonEncode({'ref': messageId}));
        await _client.from('message_relay').insert({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': 'delete',
          'client_id': _uuid.v4(),
          'ttl_hours': 1,
        });
      } catch (_) {}
    }
    await LocalMessageStore.deleteMessage(messageId);
  }

  static Future<void> deleteForMe(String messageId) => LocalMessageStore.deleteMessage(messageId);
}
