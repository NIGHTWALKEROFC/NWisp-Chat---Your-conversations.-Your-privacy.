import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'crypto_service.dart';
import 'local_media_files.dart';
import 'local_message_store.dart';
import 'media_service.dart';
import 'message_relay_service.dart' show NotSignedInException, RateLimitedException, insertMessageRelayRow;
import 'signal_session_service.dart';
export 'signal_store.dart' show IdentityChangedException;
export 'signal_session_service.dart' show ContactNotUpgradedException;
export 'message_relay_service.dart' show RateLimitedException;

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
        await insertMessageRelayRow({
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
        // This specific failure reason won't be fixed by an immediate
        // manual retry — only by the OTHER person updating their app —
        // so queue it for silent automatic retry instead (see
        // retryPendingResends) rather than surfacing yet another "try
        // again" prompt that would just fail identically.
        if (e is ContactNotUpgradedException) {
          await LocalMessageStore.queuePendingGroupResend(
            groupId: groupId,
            clientId: clientId,
            uid: uid,
            payload: text,
            messageType: messageType,
            replyToId: replyToId,
            ttlHours: ttlHours,
          );
        }
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
    bool isViewOnce = false,
  }) async {
    final myUid = _myUid;
    final clientId = _uuid.v4();
    final others = memberUids.where((u) => u != myUid).toSet().toList();

    // Feature: upload progress + retry — same insert-before-upload order
    // as MessageRelayService.sendMediaMessage (see its doc comment): the
    // bubble and progress indicator show up immediately, and a failed
    // upload leaves a 'failed' row + pending-send record instead of
    // vanishing. Group retry is upload-only (see [retryMediaMessage]
    // below) — an already-uploaded file that failed only for SOME
    // members still goes through GroupSendPartialFailure exactly as
    // before, not through the failed/retry path at all.
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
      status: 'sending',
      createdAt: createdAt,
      expiresAt: _expiryFor(createdAt, ttlHours),
      isViewOnce: isViewOnce,
    );
    await LocalMessageStore.savePendingMediaSend(
      clientId: clientId,
      conversationId: groupId,
      isGroup: true,
      extension: extension,
      mime: mime,
      durationMs: durationMs,
      ttlHours: ttlHours,
    );

    String remotePath;
    String fileKeyForMeta, fileNonceForMeta;
    try {
      final fileKey = await CryptoService.generateFileKey();
      final (encryptedBytes, fileNonce) = await CryptoService.encryptFileBytes(plainBytes, fileKey);
      remotePath = 'chat_media/$myUid/${_uuid.v4()}.enc';
      await MediaService.uploadBytes(
        Uint8List.fromList(encryptedBytes),
        _mediaBucket,
        remotePath,
        onProgress: MediaService.progressReporterFor(clientId),
      );
      fileKeyForMeta = fileKey;
      fileNonceForMeta = fileNonce;
    } catch (e) {
      await LocalMessageStore.setStatus(clientId, 'failed');
      MediaService.clearProgress(clientId);
      rethrow;
    }

    final metaPayload = jsonEncode({
      'fileKey': fileKeyForMeta,
      'nonce': fileNonceForMeta,
      'mime': mime,
      'extension': extension,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      if (durationMs != null) 'durationMs': durationMs,
      if (isViewOnce) 'viewOnce': true,
    });

    final failures = <GroupMemberSendFailure>[];
    for (final uid in others) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, metaPayload);
        await insertMessageRelayRow({
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
        if (e is ContactNotUpgradedException) {
          await LocalMessageStore.queuePendingGroupResend(
            groupId: groupId,
            clientId: clientId,
            uid: uid,
            payload: metaPayload,
            messageType: messageType,
            mediaPath: remotePath,
            ttlHours: ttlHours,
          );
        }
      }
    }

    // The upload itself succeeded, so this is 'sent' even if some members
    // individually failed (GroupSendPartialFailure below covers that) —
    // only an upload failure (above) should leave it in 'failed'/retryable.
    await LocalMessageStore.setStatus(clientId, 'sent');
    await LocalMessageStore.removePendingMediaSend(clientId);
    MediaService.clearProgress(clientId);

    if (failures.isNotEmpty) throw GroupSendPartialFailure(clientId, failures);
    return clientId;
  }

  /// Retries the UPLOAD half of a group media send that failed before any
  /// member ever received it (status 'failed', not the partial-failure
  /// case above, which is a separate "Resend to X" flow since the file
  /// already made it to Storage there). Re-reads the already-saved local
  /// file, re-uploads, then fans the relay rows out to every current
  /// member fresh.
  static Future<void> retryMediaMessage(String clientId) async {
    final myUid = _myUid;
    final pending = await LocalMessageStore.getPendingMediaSend(clientId);
    final message = await LocalMessageStore.getById(clientId);
    if (pending == null || message == null || message.mediaPath == null) {
      throw Exception('This message can no longer be retried — its local data is gone.');
    }
    final memberUids = await LocalMessageStore.cachedGroupMemberUids(pending.conversationId);
    final others = memberUids.where((u) => u != myUid).toList();

    await LocalMessageStore.setStatus(clientId, 'sending');
    String remotePath;
    String fileKey, fileNonce;
    try {
      final plainBytes = await File(message.mediaPath!).readAsBytes();
      final key = await CryptoService.generateFileKey();
      final (encryptedBytes, nonce) = await CryptoService.encryptFileBytes(plainBytes, key);
      remotePath = 'chat_media/$myUid/${_uuid.v4()}.enc';
      await MediaService.uploadBytes(
        Uint8List.fromList(encryptedBytes),
        _mediaBucket,
        remotePath,
        onProgress: MediaService.progressReporterFor(clientId),
      );
      fileKey = key;
      fileNonce = nonce;
    } catch (e) {
      await LocalMessageStore.setStatus(clientId, 'failed');
      MediaService.clearProgress(clientId);
      rethrow;
    }

    final metaPayload = jsonEncode({
      'fileKey': fileKey,
      'nonce': fileNonce,
      'mime': pending.mime,
      'extension': pending.extension,
      if (message.text.isNotEmpty) 'caption': message.text,
      if (pending.durationMs != null) 'durationMs': pending.durationMs,
      if (message.isViewOnce) 'viewOnce': true,
    });

    final failures = <GroupMemberSendFailure>[];
    for (final uid in others) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, metaPayload);
        await insertMessageRelayRow({
          'conversation_id': pending.conversationId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': message.messageType,
          'media_path': remotePath,
          'client_id': clientId,
          'ttl_hours': pending.ttlHours,
        });
      } catch (e) {
        failures.add(GroupMemberSendFailure(uid, e));
      }
    }

    await LocalMessageStore.setStatus(clientId, 'sent');
    await LocalMessageStore.removePendingMediaSend(clientId);
    MediaService.clearProgress(clientId);
    if (failures.isNotEmpty) throw GroupSendPartialFailure(clientId, failures);
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
        await insertMessageRelayRow({
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

  /// Group counterpart to MessageRelayService.editMessage — same 15-minute
  /// edit window, same 'edit' message_type. The RECEIVE side needs no
  /// group-specific code at all (see the class doc comment): each
  /// member's device picks this up through the exact same generic 'edit'
  /// case in MessageRelayService._handleRow that a 1:1 edit uses.
  static const editWindow = Duration(minutes: 15);

  static Future<void> editGroupMessage({
    required String groupId,
    required List<String> memberUids,
    required String messageId,
    required String newText,
    required DateTime originalCreatedAt,
  }) async {
    if (DateTime.now().difference(originalCreatedAt) > editWindow) {
      throw Exception('This message is too old to edit.');
    }
    final trimmed = newText.trim();
    if (trimmed.isEmpty) throw Exception('Message text cannot be empty.');

    final myUid = _myUid;
    for (final uid in memberUids.where((u) => u != myUid)) {
      try {
        final (ciphertext, nonce) =
            await SignalSessionService.instance.encryptForPeer(uid, jsonEncode({'ref': messageId, 'text': trimmed}));
        await insertMessageRelayRow({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': 'edit',
          'client_id': _uuid.v4(),
          'ttl_hours': 1,
        });
      } catch (_) {
        // Best-effort, same as reactions/deletes: one member missing an
        // edit isn't worth blocking the edit for everyone else who got it.
      }
    }
    await LocalMessageStore.editMessage(messageId, trimmed);
  }

  /// Retries delivering an ALREADY-SENT (and already-stored-locally) group
  /// text message to specific member(s) who were missed the first time —
  /// the "Resend to X" action on the partial-failure snackbar (see
  /// GroupSendPartialFailure / GroupChatScreen). Deliberately does NOT
  /// touch local storage again — the message is already sitting there
  /// from the original send, this only re-attempts the per-member
  /// encrypted fan-out, reusing the SAME clientId so it's still
  /// recognized as the one message everyone already sees rather than a
  /// duplicate.
  ///
  /// v1 limitation, flagged rather than silently shipped: this only
  /// covers text messages. A failed MEDIA send can't be safely retried
  /// this way without re-uploading the file, since the per-member
  /// ciphertext blob (the file key/nonce) that would need to be
  /// re-encrypted for the missed member isn't kept around after the
  /// original send completes — GroupChatScreen only offers this action
  /// for text messages for that reason.
  static Future<List<GroupMemberSendFailure>> resendTextMessage({
    required String groupId,
    required List<String> uids,
    required String clientId,
    required String text,
    String? replyToId,
    required int ttlHours,
  }) async {
    final myUid = _myUid;
    final failures = <GroupMemberSendFailure>[];
    for (final uid in uids.where((u) => u != myUid)) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, text);
        await insertMessageRelayRow({
          'conversation_id': groupId,
          'sender_uid': myUid,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': 'text',
          'reply_to_id': replyToId,
          'client_id': clientId,
          'ttl_hours': ttlHours,
        });
      } catch (e) {
        failures.add(GroupMemberSendFailure(uid, e));
      }
    }
    return failures;
  }

  /// Silently retries every queued resend for [groupId] — see
  /// ContactNotUpgradedException / LocalMessageStore.queuePendingGroupResend.
  /// Called when a group chat is opened (GroupChatScreen.initState) and
  /// once at app startup for every group the person is in (see
  /// GroupService.retryAllPendingResends), so a message queued because a
  /// member "hasn't updated yet" actually reaches them once they do,
  /// without the sender having to do anything or see another prompt.
  /// Entries that still fail (still not upgraded) simply stay queued for
  /// next time — no snackbar, no user-visible failure, since nothing
  /// about this attempt is actionable by the sender right now.
  static Future<void> retryPendingResends(String groupId) async {
    final pending = await LocalMessageStore.pendingGroupResends(groupId);
    if (pending.isEmpty) return;
    final myUid = _myUid;
    for (final item in pending) {
      if (item.uid == myUid) {
        await LocalMessageStore.removePendingGroupResend(item.id);
        continue;
      }
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(item.uid, item.payload);
        await insertMessageRelayRow({
          'conversation_id': item.groupId,
          'sender_uid': myUid,
          'recipient_uid': item.uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': item.messageType,
          'media_path': item.mediaPath,
          'reply_to_id': item.replyToId,
          'client_id': item.clientId,
          'ttl_hours': item.ttlHours,
        });
        await LocalMessageStore.removePendingGroupResend(item.id);
      } catch (_) {
        // Still not upgraded (or some other transient issue) — leave it
        // queued, try again next time this is called.
      }
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
        await insertMessageRelayRow({
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
