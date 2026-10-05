import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'crypto_service.dart';
import 'group_service.dart';
import 'local_media_files.dart';
import 'local_message_store.dart';
import 'media_service.dart';
import 'pin_service.dart';
import 'signal_session_service.dart';
import 'story_service.dart';
import 'poll_service.dart';
import 'auto_download_service.dart';
import 'traffic_camouflage_service.dart';
export 'signal_store.dart' show IdentityChangedException;

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

/// Thrown when the message_relay_rate_limit database trigger rejects an
/// insert (see supabase/migrations/0001_message_relay_rate_limit.sql —
/// caps each sender to 30 real messages per 10 seconds). This carries a
/// message that's safe to show directly to the person, instead of the
/// raw Postgres error text leaking into the chat UI.
class RateLimitedException implements Exception {
  final String message = "You're sending messages too fast. Please wait a moment and try again.";
  @override
  String toString() => message;
}

/// Feature: mutual timed block ("Pause this chat" — see
/// ChatFreezeService). Thrown by [MessageRelayService._checkNotFrozen]
/// when the person you're sending to has an active mutual freeze with
/// you — deliberately vague about exactly when it lifts in the message
/// text itself (PausedChatsScreen shows the precise time; this is just
/// what shows up as a send error).
class ChatFrozenException implements Exception {
  final DateTime expiresAt;
  ChatFrozenException(this.expiresAt);
  String get message => "This chat is paused right now. Check Paused chats in Settings to see when it reopens.";
  @override
  String toString() => message;
}

/// Feature: permission-gated message forwarding. Thrown by
/// [MessageRelayService.forwardTextMessage] when forwarding isn't currently
/// allowed for the chat the message would be forwarded FROM — either it was
/// never approved, the other person switched it off, or it couldn't be
/// verified right now. Deliberately fails CLOSED: if the app can't confirm
/// permission, nothing is forwarded.
class ForwardingRestrictedException implements Exception {
  final String message;
  ForwardingRestrictedException([
    this.message = 'Forwarding is restricted in this chat. Ask the other person to allow it first.',
  ]);
  @override
  String toString() => message;
}

/// Every message_relay insert, in BOTH relay services (this one and
/// GroupMessageRelayService), goes through this instead of calling
/// `_client.from('message_relay').insert` directly. It's the one place
/// that recognizes the rate-limit trigger's error and turns it into a
/// [RateLimitedException] the UI can catch and show a friendly message
/// for. Every other Postgres error is rethrown unchanged — this only
/// ever translates the one error it specifically knows about.
Future<void> insertMessageRelayRow(Map<String, dynamic> row) async {
  try {
    await Supabase.instance.client.from('message_relay').insert(row);
  } on PostgrestException catch (e) {
    final isRateLimit = e.code == 'P0001' || e.message.toLowerCase().contains('rate limit');
    if (isRateLimit) throw RateLimitedException();
    rethrow;
  }
}

/// Moves message content through Supabase as a pure, temporary relay:
/// insert -> the recipient's device picks it up over Realtime (or on
/// reconnect) -> decrypts -> saves locally -> deletes the row. Nothing about
/// message content is meant to sit in the `message_relay` table for long.
///
/// This class is ALSO, unmodified, the receive path for group messages
/// (Phase 7 — see GroupMessageRelayService for the send/fan-out side). A
/// row fanned out to a group member looks exactly like a 1:1 row to
/// everything below: same columns, same realtime subscription (filtered
/// only by `recipient_uid`), same decrypt/store/react logic. The one place
/// that genuinely needed to know the difference is _receiveMediaMessage's
/// Storage cleanup — see its comment.
class MessageRelayService {
  static final _client = Supabase.instance.client;
  static final _db = FirebaseFirestore.instance;
  static final _uuid = const Uuid();

  static RealtimeChannel? _channel;
  static Timer? _reconnectTimer;

  /// Same bucket StoryService already uses — no new Supabase bucket setup
  /// needed. Chat media lives under chat_media/{senderUid}/{uuid}.enc so
  /// the get-signed-url edge function's existing "path must start with the
  /// caller's own uid" upload check just works, unchanged.
  static const _mediaBucket = 'media';
  static const _mediaTypes = {'image', 'video', 'voice'};

  /// Group conversation ids are always "group_<uuid>" (see
  /// GroupService.newGroupId) — a 1:1 id is always two sorted uids joined
  /// with "_" and can never itself start with that literal prefix.
  static const _groupIdPrefix = 'group_';

  /// Feature: permission-gated message forwarding. Text messages have no
  /// metadata envelope (unlike media, which carries a small JSON blob), so a
  /// forwarded text message is sent as this marker followed by the text —
  /// INSIDE the end-to-end-encrypted payload, so neither Supabase nor
  /// Firebase can tell a forward from an ordinary message. The receiving
  /// side strips it in [_handleRow] and just sets LocalMessage.isForwarded.
  /// The characters are from a Unicode private-use block, so ordinary typed
  /// text will never start with them.
  static const _forwardMarker = '\u{E0F1}NWFWD1\u{E0F1}';

  /// Feature: traffic pattern camouflage. See TrafficCamouflageService's
  /// own doc comment for the full picture -- these three are the
  /// mechanics: [_padPayload]/[_unpadPayload] pad a text payload out to
  /// one of [_paddingBuckets] bytes (inside the end-to-end-encrypted
  /// content, so only the real recipient ever sees the unpadded text or
  /// even that padding happened at all), and [_decoyMarker] is what a
  /// decoy message's plaintext starts with so the receiving device can
  /// recognize and silently discard it (see [_handleRow]'s text branch).
  /// Both markers use Unicode private-use characters, same as
  /// [_forwardMarker] above -- ordinary typed text will never start with
  /// either.
  static const _paddingMarker = '\u{E0F2}';
  static const _decoyMarker = '\u{E0F3}NWDECOY\u{E0F3}';
  static const List<int> _paddingBuckets = [64, 128, 256, 512, 1024, 2048, 4096, 8192];

  static String _padPayload(String payload) {
    final withMarker = '$payload$_paddingMarker';
    final baseLen = utf8.encode(withMarker).length;
    final bucket = _paddingBuckets.firstWhere((b) => b >= baseLen, orElse: () => -1);
    // Longer than the biggest bucket (a long message) -- left unpadded
    // rather than truncating real content; only its length beyond the
    // top bucket is ever revealed, same as before this feature existed.
    if (bucket == -1) return payload;
    return withMarker + ('0' * (bucket - baseLen));
  }

  static String _unpadPayload(String payload) {
    final idx = payload.indexOf(_paddingMarker);
    return idx == -1 ? payload : payload.substring(0, idx);
  }

  /// A safe accessor instead of a bare `!` null-check — a null session here
  /// (e.g. an expired/revoked token) now surfaces as a clear, catchable
  /// NotSignedInException instead of an unhandled null-check crash.
  static String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw NotSignedInException();
    return uid;
  }

  /// ttlHours == 0 means "never auto-delete" (the new default — see the
  /// settings/chat-settings TTL pickers) rather than "expires instantly".
  /// A null expiresAt is what LocalMessageStore.purgeExpired() already
  /// treats as "keep forever" (its WHERE clause only matches non-null,
  /// past expiresAt rows), so this is the only place that needs to know
  /// about the 0-means-never convention.
  static DateTime? _expiryFor(DateTime createdAt, int ttlHours) {
    if (ttlHours <= 0) return null;
    return createdAt.add(Duration(hours: ttlHours));
  }

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
    _startPolling();
  }

  // BUGFIX (\"messages are sent but the other side only receives them rarely,
  // or after a call / an app restart\"): receiving depended ONLY on Supabase
  // Realtime pushing each new row. When Realtime doesn't push (the table is
  // not in the `supabase_realtime` publication, or the socket silently
  // dropped) nothing arrived until the next full catch-up — which only ran at
  // app start or when a reconnect happened (a call ending reconnects the
  // network, hence \"it loads after the call\"). A light poll now checks the
  // inbox every few seconds as a safety net. Realtime still delivers instantly
  // when it works.
  static Timer? _pollTimer;
  static bool _polling = false;

  static void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_polling || FirebaseAuth.instance.currentUser == null) return;
      _polling = true;
      try {
        await _catchUp();
      } catch (_) {
        // offline — try again on the next tick
      } finally {
        _polling = false;
      }
    });
  }

  /// Checks the inbox right now (e.g. when the app comes back to the front).
  static Future<void> refreshNow() async {
    if (_polling || FirebaseAuth.instance.currentUser == null) return;
    _polling = true;
    try {
      await _catchUp();
    } catch (_) {} finally {
      _polling = false;
    }
  }

  // Signal's ratchet is order-sensitive and can't decrypt the same message
  // twice, so rows are handled strictly one at a time and never twice at once
  // (realtime + the poll above can both see the same row).
  static Future<void> _queue = Future.value();
  static final Set<dynamic> _inFlight = {};

  static Future<void> _handleRowOnce(Map<String, dynamic> row) {
    final id = row['id'];
    if (_inFlight.contains(id)) return Future.value();
    _inFlight.add(id);
    final completer = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _handleRow(row);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _inFlight.remove(id);
      }
    });
    return completer.future;
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
            _handleRowOnce(payload.newRecord).catchError((Object e) {
              // BUGFIX: this used to swallow the error completely — a
              // message stuck failing to decrypt (e.g. a Signal session
              // that's gotten out of sync between two people) looked
              // EXACTLY like "sent but never received": the sender's row
              // inserts fine (that's sending), the row stays in
              // message_relay because _handleRow's own catch below
              // deliberately doesn't delete it on failure, and it keeps
              // retrying — and keeps silently failing — forever, with
              // nothing anywhere showing that anything is wrong.
              // debugPrint at minimum surfaces it in the device log
              // instead of it looking like nothing happened at all.
              debugPrint('message_relay: failed to handle live row ${payload.newRecord['id']}: $e');
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
    _pollTimer?.cancel();
    _pollTimer = null;
    _reconnectTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
  }

  static Future<void> _catchUp() async {
    final rows = await _client.from('message_relay').select().eq('recipient_uid', _myUid).order('created_at', ascending: true);
    for (final row in rows) {
      try {
        await _handleRowOnce(row);
      } catch (e) {
        // Leave this one for the next catch-up rather than letting one bad
        // row block the rest of the inbox from being processed — but log
        // it (see the matching comment in _subscribe above for why this
        // used to be a silent, invisible failure).
        debugPrint('message_relay: failed to handle catch-up row ${row['id']}: $e');
      }
    }
  }

  /// [row]'s `nonce` column now carries the Signal message type marker
  /// ('3' = first message in a session, carries the X3DH handshake; '1' =
  /// every message after, pure ratchet-advanced ciphertext) rather than a
  /// literal crypto nonce — the Double Ratchet manages nonces/counters
  /// internally, so there's nothing else that column needs to hold.
  static Future<String> _decryptRow(Map<String, dynamic> row, String senderUid) async {
    return SignalSessionService.instance.decryptFromPeer(
      senderUid,
      row['ciphertext'] as String,
      row['nonce'] as String,
    );
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
        final conversationId = row['conversation_id'] as String;
        // Group conversations track receipts PER MEMBER (see
        // LocalMessageStore.setGroupReceipt / GroupChatScreen's read
        // indicator) rather than overwriting one shared `status` column,
        // which could previously only ever reflect whichever receipt
        // happened to arrive last.
        if (conversationId.startsWith(_groupIdPrefix)) {
          await LocalMessageStore.setGroupReceipt(
            conversationId: conversationId,
            messageId: data['ref'] as String,
            memberUid: senderUid,
            status: data['status'] as String,
          );
        } else {
          await LocalMessageStore.setStatus(data['ref'] as String, data['status'] as String);
        }
        break;
      case 'delete':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.deleteMessage(data['ref'] as String);
        break;
      case 'edit':
        // Shared receive path for BOTH 1:1 and group edits (see
        // GroupMessageRelayService.editGroupMessage — it fans this same
        // message_type out to every other member, and this generic
        // handler picks it up on each of their devices exactly like a
        // 1:1 edit). The sender already enforced the edit-time-window
        // check before sending (see editMessage below); the receive side
        // trusts that the same way it already trusts a 'delete' or
        // 'reaction' row without re-verifying timing itself.
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.editMessage(data['ref'] as String, data['text'] as String);
        break;
      case 'clear':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.clearConversation(data['conversationId'] as String);
        break;
      case 'reaction':
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await LocalMessageStore.setReaction(data['ref'] as String, senderUid, data['emoji'] as String?);
        break;
      case 'pin_update':
        // Feature: shared pinned messages — see PinService's doc comment
        // and sendPinUpdate above. setPinned (not togglePin) because this
        // message already says exactly what state to end up in.
        final data = jsonDecode(payload) as Map<String, dynamic>;
        await PinService.setPinned(row['conversation_id'] as String, data['ref'] as String, data['pinned'] as bool);
        break;
      // Feature: WhatsApp-style stories — see StoryService. These four row
      // types are tiny encrypted notes between phones; none of them is a chat
      // message, so none must ever reach the default (text) branch below.
      case 'poll_vote':
        await PollService.instance.receiveVote(voterUid: senderUid, payload: payload);
        break;
      case 'story':
        await StoryService.instance.receiveStory(
          ownerUid: senderUid,
          payload: payload,
          remotePath: row['media_path'] as String?,
        );
        break;
      case 'story_view':
        await StoryService.instance.receiveView(viewerUid: senderUid, payload: payload);
        break;
      case 'story_like':
        await StoryService.instance.receiveLike(viewerUid: senderUid, payload: payload);
        break;
      case 'story_delete':
        await StoryService.instance.receiveDelete(ownerUid: senderUid, payload: payload);
        break;
      case 'screenshot':
        // Feature: screenshot alert. The other person's phone reported that
        // they pressed the screenshot buttons in this chat (the screenshot
        // itself was blocked). Shown as a small centered notice in the chat
        // — see ChatDetailScreen's 'screenshot_notice' handling. Only ever
        // sent for 1:1 chats, so no group branch is needed.
        final noticeTtl = (row['ttl_hours'] as num?)?.toInt() ?? 0;
        final noticeAt = DateTime.now();
        await LocalMessageStore.insert(
          id: row['client_id'] as String,
          conversationId: row['conversation_id'] as String,
          peerUid: senderUid,
          senderUid: senderUid,
          isMine: false,
          text: 'Screenshot attempt',
          messageType: 'screenshot_notice',
          mediaPath: null,
          replyToId: null,
          status: 'delivered',
          createdAt: noticeAt,
          expiresAt: _expiryFor(noticeAt, noticeTtl),
        );
        break;
      default:
        // Feature: announcement-only groups. The relay can't read messages, so
        // THIS phone is the one that enforces "only admins can post": a
        // message from a non-admin in an announcement-only group is dropped
        // here (after decrypting, so the encryption session stays in step)
        // and never stored, shown or acknowledged. If the group can't be
        // looked up right now (offline) mayPost throws, the row is kept, and
        // it is simply retried later — nothing is wrongly accepted or lost.
        final postGroupId = row['conversation_id'] as String;
        if (postGroupId.startsWith(_groupIdPrefix) && !await GroupService.instance.mayPost(postGroupId, uid: senderUid)) {
          break;
        }
        final ttlHours = (row['ttl_hours'] as num?)?.toInt() ?? 0;
        final createdAt = DateTime.now();
        if (_mediaTypes.contains(messageType)) {
          await _receiveMediaMessage(row: row, senderUid: senderUid, payload: payload, createdAt: createdAt, ttlHours: ttlHours);
        } else {
          // Feature: traffic pattern camouflage — see [_decoyMarker]. A
          // decoy is unwrapped exactly like a real message (padding
          // stripped the same way, so its ciphertext was byte-for-byte
          // the same shape as a real padded message to anyone who
          // couldn't decrypt it) but is never actually stored or shown
          // once this device CAN read it. The receipt below still gets
          // sent for it regardless — see sendDecoyMessage's own note on
          // why that matters for the camouflage to actually work.
          var incomingText = _unpadPayload(payload);
          final isDecoy = messageType == 'text' && incomingText.startsWith(_decoyMarker);
          // Feature: permission-gated forwarding — see [_forwardMarker].
          var incomingForwarded = false;
          if (!isDecoy && messageType == 'text' && incomingText.startsWith(_forwardMarker)) {
            incomingText = incomingText.substring(_forwardMarker.length);
            incomingForwarded = true;
          }
          if (!isDecoy) {
            await LocalMessageStore.insert(
              id: row['client_id'] as String,
              conversationId: row['conversation_id'] as String,
              peerUid: senderUid,
              senderUid: senderUid,
              isMine: false,
              text: incomingText,
              messageType: messageType,
              mediaPath: null,
              replyToId: row['reply_to_id'] as String?,
              status: 'delivered',
              createdAt: createdAt,
              expiresAt: _expiryFor(createdAt, ttlHours),
              isForwarded: incomingForwarded,
            );
          }
        }
        await _sendReceipt(
          conversationId: row['conversation_id'] as String,
          toUid: senderUid,
          ref: row['client_id'] as String,
          status: 'delivered',
        );
    }

    await _client.from('message_relay').delete().eq('id', row['id']);
  }

  /// Handles an incoming image/video/voice message. [payload] is the small
  /// JSON blob (fileKey, nonce, mime, extension, fileName, plus optional
  /// width/height/durationMs) that was itself already decrypted via the
  /// normal Signal peer scheme in [_decryptRow] — the actual media bytes
  /// are separately encrypted under the random key inside that JSON.
  static Future<void> _receiveMediaMessage({
    required Map<String, dynamic> row,
    required String senderUid,
    required String payload,
    required DateTime createdAt,
    required int ttlHours,
  }) async {
    final meta = jsonDecode(payload) as Map<String, dynamic>;
    final remotePath = row['media_path'] as String?;
    if (remotePath == null) {
      throw Exception('Media message is missing its storage path.');
    }
    final conversationId = row['conversation_id'] as String;

    // Group security setting: media auto-download restrictions. When a
    // group has this off, don't fetch/decrypt now — store what a manual
    // download will need instead (this relay row, the only OTHER place
    // that info exists, gets deleted right after this method returns
    // either way — see _handleRow) and let the person tap to fetch it
    // later (see downloadPendingMedia). 1:1 chats are unaffected — this
    // setting only exists on group docs.
    // Feature: auto-download rules (Settings → Data and storage) apply to
    // every chat; a group can ALSO switch auto-download off for itself.
    final groupBlocks = conversationId.startsWith(_groupIdPrefix) && !await GroupService.instance.isMediaAutoDownloadEnabled(conversationId);
    final ruleBlocks = !await AutoDownloadService.instance.allowedNow(row['message_type'] as String);
    if (groupBlocks || ruleBlocks) {
      await LocalMessageStore.insert(
        id: row['client_id'] as String,
        conversationId: conversationId,
        peerUid: senderUid,
        senderUid: senderUid,
        isMine: false,
        text: (meta['caption'] as String?) ?? '',
        messageType: row['message_type'] as String,
        mediaPath: null,
        replyToId: row['reply_to_id'] as String?,
        status: 'delivered',
        createdAt: createdAt,
        expiresAt: _expiryFor(createdAt, ttlHours),
        pendingMediaMeta: {...meta, 'remotePath': remotePath},
        isViewOnce: meta['viewOnce'] == true,
      );
      return;
    }

    final encryptedBytes = await MediaService.downloadBytes(_mediaBucket, remotePath);
    final plainBytes = await CryptoService.decryptFileBytes(
      encryptedBytes,
      meta['nonce'] as String,
      meta['fileKey'] as String,
    );
    final extension = (meta['extension'] as String?) ?? 'bin';
    final localPath = await LocalMediaFiles.save(Uint8List.fromList(plainBytes), extension);

    await LocalMessageStore.insert(
      id: row['client_id'] as String,
      conversationId: conversationId,
      peerUid: senderUid,
      senderUid: senderUid,
      isMine: false,
      text: (meta['caption'] as String?) ?? '',
      messageType: row['message_type'] as String,
      mediaPath: localPath,
      replyToId: row['reply_to_id'] as String?,
      status: 'delivered',
      createdAt: createdAt,
      expiresAt: _expiryFor(createdAt, ttlHours),
      isViewOnce: meta['viewOnce'] == true,
    );

    // Forward-only for 1:1 chats: now that our own local copy is safely
    // saved, the encrypted blob has no reason to keep sitting in Supabase
    // Storage. Group chats are the one exception (Phase 7): the SAME
    // media_path is shared by every fanned-out copy of a group media
    // message (see GroupMessageRelayService.sendGroupMediaMessage), so an
    // early recipient deleting it would 404 the download for every other
    // member who hasn't opened the chat yet. For groups, the blob is left
    // in Storage and cleaned up later by scripts/cleanup.js's normal
    // TTL-based sweep instead.
    // UNVERIFIED: this branch (the group half) hasn't been exercised on a
    // real device with 3+ accounts — please test a group photo/voice send
    // with multiple recipients before relying on it.
    final isGroupConversation = (row['conversation_id'] as String).startsWith(_groupIdPrefix);
    if (!isGroupConversation) {
      try {
        await MediaService.deleteRemote(_mediaBucket, remotePath);
      } catch (_) {}
    }
  }

  /// Group security setting: media auto-download restrictions — completes
  /// a download [_receiveMediaMessage] deliberately deferred. Called from
  /// a tap on the "tap to download" bubble state (see GroupChatScreen).
  /// Leaves the remote blob in place either way — same TTL-cleanup
  /// reasoning as the group branch above, since another member who
  /// hasn't opened the chat yet may still need it.
  static Future<void> downloadPendingMedia(String messageId) async {
    final meta = await LocalMessageStore.getPendingMediaMeta(messageId);
    if (meta == null) return; // nothing pending (already downloaded, or not a media message)
    final remotePath = meta['remotePath'] as String;
    final encryptedBytes = await MediaService.downloadBytes(_mediaBucket, remotePath);
    final plainBytes = await CryptoService.decryptFileBytes(
      encryptedBytes,
      meta['nonce'] as String,
      meta['fileKey'] as String,
    );
    final extension = (meta['extension'] as String?) ?? 'bin';
    final localPath = await LocalMediaFiles.save(Uint8List.fromList(plainBytes), extension);
    await LocalMessageStore.resolvePendingMedia(messageId, localPath, (meta['caption'] as String?) ?? '');
    // 1:1 chats: our copy is safe now, so the temporary server copy can go.
    // (Best effort: the relay row that authorises the delete may already be
    // gone, in which case the server's cleanup job removes the file.)
    final pendingConversation = (await LocalMessageStore.getById(messageId))?.conversationId ?? '';
    if (!pendingConversation.startsWith(_groupIdPrefix)) {
      try {
        await MediaService.deleteRemote(_mediaBucket, remotePath);
      } catch (_) {}
    }
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

  /// Feature: mutual timed block. Same doc id convention as
  /// ChatFreezeService — sorted pair, so both people's sends check the
  /// exact same document. Only gates actually sending new content
  /// (called from [sendMessage]/[sendMediaMessage]); receipts, reactions,
  /// edits, and deletes for messages already sent before the freeze
  /// started are left alone, matching the requested scope of "can't send
  /// messages", not "the app stops working entirely".
  static Future<void> _checkNotFrozen(String otherUid) async {
    final ids = [_myUid, otherUid]..sort();
    final doc = await _db.collection('timedFreezes').doc('${ids[0]}_${ids[1]}').get();
    final expiresAt = (doc.data()?['expiresAt'] as Timestamp?)?.toDate();
    if (expiresAt != null && expiresAt.isAfter(DateTime.now())) {
      throw ChatFrozenException(expiresAt);
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
    bool isForwarded = false,
    bool silent = false,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();

    await _checkNotBlocked(recipientUid);
    await _checkNotFrozen(recipientUid);
    final clientId = _uuid.v4();
    // Always fetch a live public key for sends specifically — if we
    // silently encrypted with a stale cached key here, the recipient would
    // never be able to decrypt it and we'd have no way to know the send
    // "failed", since the Supabase insert itself always succeeds.
    //
    // A forwarded text message travels as marker + text (see
    // [_forwardMarker]); an ordinary message is sent exactly as before.
    final payload = (isForwarded && messageType == 'text') ? '$_forwardMarker$text' : text;
    // Feature: traffic pattern camouflage — padding only applies to text,
    // and only when this specific chat has it on (global default or a
    // per-chat override — see TrafficCamouflageService). Padding happens
    // BEFORE encryption, so it's invisible in the ciphertext's length
    // beyond which fixed bucket it landed in.
    final shouldPad = messageType == 'text' && await TrafficCamouflageService.instance.isEffectiveEnabledForChat(conversationId);
    final outgoingPayload = shouldPad ? _padPayload(payload) : payload;
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(recipientUid, outgoingPayload);

    try {
      await insertMessageRelayRow({
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
        // Feature: silent send. Only ever added when true, so an ordinary
        // message is byte-for-byte what it was before. The server's push
        // function (send-push) sees this flag and doesn't notify the
        // recipient's phone; the message still arrives and counts as unread.
        if (silent) 'silent': true,
      });
    } on PostgrestException catch (e) {
      // Only silent sends ever include the column, so this can only mean the
      // database hasn't been given it yet (supabase/migrations/0006).
      if (silent && e.message.toLowerCase().contains('silent')) {
        throw Exception(
          "Silent send isn't set up on the server yet. Run migration 0006_silent_messages.sql in Supabase, "
          "or send this one normally.",
        );
      }
      rethrow;
    }

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
      expiresAt: _expiryFor(createdAt, ttlHours),
      isForwarded: isForwarded && messageType == 'text',
    );
    return clientId;
  }

  /// Feature: traffic pattern camouflage. Called by
  /// TrafficCamouflageService's decoy scheduler, never directly by any
  /// screen. Sent with messageType 'text' — deliberately IDENTICAL at the
  /// relay-row level to a real text message (same columns, same
  /// message_type value, and padded to the same bucket sizes — see
  /// [_padPayload]) so nothing about the row itself marks it as a decoy
  /// to anyone who can see `message_relay` but not decrypt it. The only
  /// thing that does mark it is the [_decoyMarker] prefix inside the
  /// encrypted plaintext, which only the real recipient's device can
  /// ever read (see [_handleRow]'s text branch for the matching check).
  ///
  /// Deliberately does NOT call LocalMessageStore.insert on this
  /// (sending) side either — a decoy must never appear in the sender's
  /// own chat UI any more than the recipient's.
  static Future<void> sendDecoyMessage({required String conversationId, required String recipientUid}) async {
    if (FirebaseAuth.instance.currentUser == null) return;
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(recipientUid, _padPayload(_decoyMarker));
    await insertMessageRelayRow({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': recipientUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'text',
      'media_path': null,
      'reply_to_id': null,
      'client_id': _uuid.v4(),
      'ttl_hours': 0,
    });
  }

  /// Feature: permission-gated message forwarding — forwards ONE text
  /// message that lives in [sourceConversationId] into a different 1:1
  /// chat ([destConversationId] / [destPeerUid]).
  ///
  /// Permission is checked HERE, not just in the UI: the source
  /// conversation's `forwardingEnabled` flag is read straight from the
  /// server (never the offline cache, which could be stale after the other
  /// person switched forwarding off), and anything other than a clear "yes"
  /// throws [ForwardingRestrictedException].
  ///
  /// Honest limit: this stops the app itself from forwarding without
  /// permission. It can't stop someone from retyping or screenshotting what
  /// they can already read — no messenger can.
  static Future<String> forwardTextMessage({
    required String sourceConversationId,
    required String destConversationId,
    required String destPeerUid,
    required String text,
    required int ttlHours,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();
    if (sourceConversationId.startsWith(_groupIdPrefix)) {
      throw ForwardingRestrictedException('Forwarding from group chats isn\'t available.');
    }
    Map<String, dynamic>? convo;
    try {
      final doc = await _db
          .collection('conversations')
          .doc(sourceConversationId)
          .get(const GetOptions(source: Source.server));
      convo = doc.data();
    } catch (_) {
      throw ForwardingRestrictedException(
        "Couldn't confirm that forwarding is allowed right now. Check your connection and try again.",
      );
    }
    final participants = List<String>.from(convo?['participants'] ?? const []);
    if (convo == null || convo['forwardingEnabled'] != true || !participants.contains(_myUid)) {
      throw ForwardingRestrictedException();
    }
    return sendMessage(
      conversationId: destConversationId,
      recipientUid: destPeerUid,
      text: text,
      ttlHours: ttlHours,
      isForwarded: true,
    );
  }

  /// Sends an image/video/voice message. [plainBytes] must already be
  /// compressed to fit the app's size limit (see MediaCompressionService) —
  /// this method only handles encryption, upload, and the relay/local-store
  /// bookkeeping, not compression itself.
  ///
  /// The file gets a brand-new random AES-256 key (see
  /// CryptoService.generateFileKey); only the encrypted bytes are uploaded
  /// to Supabase, and only that random key (32 bytes) travels through the
  /// Double Ratchet as part of a small JSON blob — Supabase never has
  /// anything it could decrypt on its own.
  static Future<String> sendMediaMessage({
    required String conversationId,
    required String recipientUid,
    required List<int> plainBytes,
    required String messageType, // 'image' | 'video' | 'voice'
    required String extension,
    required String mime,
    String? caption,
    int? durationMs,
    required int ttlHours,
    bool isViewOnce = false,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();
    await _checkNotBlocked(recipientUid);
    await _checkNotFrozen(recipientUid);

    final clientId = _uuid.v4();

    // Feature: upload progress + retry. The local row (status 'sending')
    // and local media copy are created FIRST, before any network call —
    // so the bubble shows up in the chat immediately with a progress
    // indicator, instead of the UI showing nothing at all until the whole
    // upload finishes. [MediaService.uploadProgress] is what the bubble
    // widget listens to for the live percentage.
    final localPath = await LocalMediaFiles.save(Uint8List.fromList(plainBytes), extension);
    final createdAt = DateTime.now();
    await LocalMessageStore.insert(
      id: clientId,
      conversationId: conversationId,
      peerUid: recipientUid,
      senderUid: _myUid,
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
      conversationId: conversationId,
      recipientUid: recipientUid,
      isGroup: false,
      extension: extension,
      mime: mime,
      durationMs: durationMs,
      ttlHours: ttlHours,
    );

    try {
      final fileKey = await CryptoService.generateFileKey();
      final (encryptedBytes, fileNonce) = await CryptoService.encryptFileBytes(plainBytes, fileKey);
      final remotePath = 'chat_media/$_myUid/${_uuid.v4()}.enc';
      await MediaService.uploadBytes(
        Uint8List.fromList(encryptedBytes),
        _mediaBucket,
        remotePath,
        onProgress: MediaService.progressReporterFor(clientId),
      );

      final metaPayload = jsonEncode({
        'fileKey': fileKey,
        'nonce': fileNonce,
        'mime': mime,
        'extension': extension,
        if (caption != null && caption.isNotEmpty) 'caption': caption,
        if (durationMs != null) 'durationMs': durationMs,
        if (isViewOnce) 'viewOnce': true,
      });
      final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(recipientUid, metaPayload);

      await insertMessageRelayRow({
        'conversation_id': conversationId,
        'sender_uid': _myUid,
        'recipient_uid': recipientUid,
        'ciphertext': ciphertext,
        'nonce': nonce,
        'message_type': messageType,
        'media_path': remotePath,
        'client_id': clientId,
        'ttl_hours': ttlHours,
      });

      await LocalMessageStore.setStatus(clientId, 'sent');
      await LocalMessageStore.removePendingMediaSend(clientId);
      MediaService.clearProgress(clientId);
      return clientId;
    } catch (e) {
      // Left in 'failed' status with its pending-send row intact — see
      // [retryMediaMessage]. The bubble already exists (inserted above),
      // so the person sees a real "tap to retry" message instead of the
      // send silently vanishing.
      await LocalMessageStore.setStatus(clientId, 'failed');
      MediaService.clearProgress(clientId);
      rethrow;
    }
  }

  /// Retries a photo/video/voice send that's sitting in 'failed' status —
  /// the local file is already on disk (see [sendMediaMessage]'s
  /// insert-before-upload order), so this just redoes the
  /// encrypt-upload-relay steps without asking the user to re-pick
  /// anything. Throws the same exceptions [sendMediaMessage] would if the
  /// retry itself fails again (still blocked, still offline, etc.) —
  /// callers should catch those the same way.
  static Future<void> retryMediaMessage(String clientId) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();
    final pending = await LocalMessageStore.getPendingMediaSend(clientId);
    final message = await LocalMessageStore.getById(clientId);
    if (pending == null || message == null || message.mediaPath == null) {
      throw Exception('This message can no longer be retried — its local data is gone.');
    }
    final recipientUid = pending.recipientUid;
    if (recipientUid == null) throw Exception('Missing recipient for retry.');
    await _checkNotBlocked(recipientUid);
    await _checkNotFrozen(recipientUid);

    await LocalMessageStore.setStatus(clientId, 'sending');
    try {
      final plainBytes = await File(message.mediaPath!).readAsBytes();
      final fileKey = await CryptoService.generateFileKey();
      final (encryptedBytes, fileNonce) = await CryptoService.encryptFileBytes(plainBytes, fileKey);
      final remotePath = 'chat_media/$_myUid/${_uuid.v4()}.enc';
      await MediaService.uploadBytes(
        Uint8List.fromList(encryptedBytes),
        _mediaBucket,
        remotePath,
        onProgress: MediaService.progressReporterFor(clientId),
      );

      final metaPayload = jsonEncode({
        'fileKey': fileKey,
        'nonce': fileNonce,
        'mime': pending.mime,
        'extension': pending.extension,
        if (message.text.isNotEmpty) 'caption': message.text,
        if (pending.durationMs != null) 'durationMs': pending.durationMs,
        if (message.isViewOnce) 'viewOnce': true,
      });
      final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(recipientUid, metaPayload);

      await insertMessageRelayRow({
        'conversation_id': pending.conversationId,
        'sender_uid': _myUid,
        'recipient_uid': recipientUid,
        'ciphertext': ciphertext,
        'nonce': nonce,
        'message_type': message.messageType,
        'media_path': remotePath,
        'client_id': clientId,
        'ttl_hours': pending.ttlHours,
      });

      await LocalMessageStore.setStatus(clientId, 'sent');
      await LocalMessageStore.removePendingMediaSend(clientId);
      MediaService.clearProgress(clientId);
    } catch (e) {
      await LocalMessageStore.setStatus(clientId, 'failed');
      MediaService.clearProgress(clientId);
      rethrow;
    }
  }

  /// How long after the ORIGINAL send a text message can still be edited
  /// — matches the spirit of WhatsApp/Telegram's own edit windows. Past
  /// this, "editing" stops being "I made a typo" and starts being able to
  /// rewrite something the recipient may have already read, screenshotted,
  /// or replied to. Enforced here (send side) — see the 'edit' case in
  /// _handleRow for the (trusting) receive side.
  static const editWindow = Duration(minutes: 15);

  /// Edits a previously sent TEXT message. Media/voice messages can't be
  /// edited the same way (there's no meaningful "corrected" version of a
  /// photo already sent) — chat_detail_screen.dart only offers this
  /// action for messageType == 'text' in the first place.
  static Future<void> editMessage({
    required String conversationId,
    required String toUid,
    required String messageId,
    required String newText,
    required DateTime originalCreatedAt,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) throw NotSignedInException();
    if (DateTime.now().difference(originalCreatedAt) > editWindow) {
      throw Exception('This message is too old to edit.');
    }
    final trimmed = newText.trim();
    if (trimmed.isEmpty) throw Exception('Message text cannot be empty.');

    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(
      toUid,
      jsonEncode({'ref': messageId, 'text': trimmed}),
    );
    await insertMessageRelayRow({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'edit',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
    await LocalMessageStore.editMessage(messageId, trimmed);
  }

  static Future<void> _sendReceipt({
    required String conversationId,
    required String toUid,
    required String ref,
    required String status,
  }) async {
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'ref': ref, 'status': status}));
    await insertMessageRelayRow({
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

  /// Group security setting: read receipts toggle. Gated right here,
  /// rather than in the UI that calls this — so it works no matter which
  /// screen calls it, and so a group with receipts off never even
  /// generates the relay row in the first place (nothing to leak, not
  /// just nothing shown). 1:1 conversationIds (which never start with
  /// "group_") are completely unaffected — this feature is group-only.
  static Future<bool> _receiptsAllowed(String conversationId) async {
    if (!conversationId.startsWith(_groupIdPrefix)) return true;
    return GroupService.instance.isReadReceiptsEnabled(conversationId);
  }

  static Future<void> sendReadReceipt({required String conversationId, required String toUid, required String ref}) async {
    if (!await _receiptsAllowed(conversationId)) return;
    return _sendReceipt(conversationId: conversationId, toUid: toUid, ref: ref, status: 'read');
  }

  static Future<void> sendReaction({
    required String conversationId,
    required String toUid,
    required String messageId,
    required String? emoji,
  }) async {
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'ref': messageId, 'emoji': emoji}));
    await insertMessageRelayRow({
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

  /// Feature: shared pinned messages. Tells the other person a message was
  /// pinned/unpinned so both sides show the same pin — see PinService's
  /// own doc comment for the full picture. A tiny control message, same
  /// shape and same 1-hour throwaway TTL as [sendReaction] above.
  static Future<void> sendPinUpdate({
    required String conversationId,
    required String toUid,
    required String messageId,
    required bool pinned,
  }) async {
    final (ciphertext, nonce) =
        await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'ref': messageId, 'pinned': pinned}));
    await insertMessageRelayRow({
      'conversation_id': conversationId,
      'sender_uid': _myUid,
      'recipient_uid': toUid,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'message_type': 'pin_update',
      'client_id': _uuid.v4(),
      'ttl_hours': 1,
    });
  }

  /// Feature: screenshot alert. Tells the other person in a 1:1 chat that
  /// this device just tried to take a screenshot (which was blocked).
  ///
  /// Best-effort by design: if the person is blocked or frozen, the keys
  /// need re-verifying, or the network is down, nothing is sent and nothing
  /// is surfaced — a failed alert must never get in the way of the chat.
  /// Not counted by the message rate limiter (only text/image/video/voice
  /// are), and the row is a control message so it never triggers a push.
  static Future<void> sendScreenshotNotice({
    required String conversationId,
    required String toUid,
    required int ttlHours,
  }) async {
    try {
      if (FirebaseAuth.instance.currentUser == null) return;
      if (conversationId.startsWith(_groupIdPrefix)) return;
      await _checkNotBlocked(toUid);
      await _checkNotFrozen(toUid);
      final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'v': 1}));
      await insertMessageRelayRow({
        'conversation_id': conversationId,
        'sender_uid': _myUid,
        'recipient_uid': toUid,
        'ciphertext': ciphertext,
        'nonce': nonce,
        'message_type': 'screenshot',
        'client_id': _uuid.v4(),
        'ttl_hours': ttlHours,
      });
    } catch (_) {
      // See the doc comment above — deliberately silent.
    }
  }

  /// Telegram-style "delete for everyone": removes it from our own device
  /// AND tells the peer's device to remove it from theirs. Nothing to
  /// un-send server-side because nothing stays server-side.
  static Future<void> deleteForEveryone({required String conversationId, required String toUid, required String messageId}) async {
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'ref': messageId}));
    await insertMessageRelayRow({
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
    final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(toUid, jsonEncode({'conversationId': conversationId}));
    await insertMessageRelayRow({
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
