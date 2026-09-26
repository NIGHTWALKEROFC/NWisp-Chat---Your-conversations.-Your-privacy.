import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/local_message.dart';
import 'crypto_service.dart';
import 'local_media_files.dart';
import 'media_vault_service.dart';

/// On-device store for message content. This is now the ONLY place message
/// text lives long-term — Supabase only ever holds a message transiently in
/// transit, and Firestore never sees message content at all. Every row's
/// `enc_text` column is AES-GCM ciphertext under a device-local key (see
/// CryptoService.encryptLocal) — plaintext only ever exists in memory.
///
/// Phase 7 (group chats) adds one more table, `group_meta` — a local cache
/// of each group's name/avatar/member list, kept fresh by
/// GroupService.startCaching(). It exists purely so the chat list can show
/// a group's name/avatar even before (or without) a live Firestore read;
/// the `messages` table itself needed NO schema change for groups — a
/// group message row looks exactly like a 1:1 row, just with
/// conversation_id set to a "group_..." id instead of two sorted uids.
class LocalMessageStore {
  static Database? _db;
  static final Map<String, StreamController<List<LocalMessage>>> _convoControllers = {};
  static final _summaryController = StreamController<List<ConversationSummary>>.broadcast();
  // messageId -> {memberUid -> 'delivered'|'read'} — see watchGroupReceipts.
  static final Map<String, StreamController<Map<String, Map<String, String>>>> _receiptControllers = {};

  static const _groupPrefix = 'group_';

  // Feature: "Mark as unread" — conversationIds the person has manually
  // flagged as unread. Device-local only (see setManualUnread).
  static final _manualUnreadController = StreamController<Set<String>>.broadcast();

  // Bug fix: "Delete chat" (home screen long-press) — conversationIds the
  // person has removed from THEIR OWN chat list. Device-local only, same
  // as manual_unread above. See markChatDeletedLocally's doc comment for
  // why this needs its own table instead of just clearing messages.
  static final _deletedChatsController = StreamController<Set<String>>.broadcast();

  static Future<void> init() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'nwisp_messages.db');
    _db = await openDatabase(
      path,
      version: 11,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            peer_uid TEXT NOT NULL,
            sender_uid TEXT NOT NULL,
            is_mine INTEGER NOT NULL,
            enc_text TEXT NOT NULL,
            enc_nonce TEXT NOT NULL,
            message_type TEXT NOT NULL DEFAULT 'text',
            media_path TEXT,
            reply_to_id TEXT,
            reactions TEXT NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'sent',
            created_at INTEGER NOT NULL,
            expires_at INTEGER,
            edited_at INTEGER,
            pending_media_meta TEXT,
            is_view_once INTEGER NOT NULL DEFAULT 0,
            view_once_consumed INTEGER NOT NULL DEFAULT 0,
            starred INTEGER NOT NULL DEFAULT 0,
            is_forwarded INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_conv ON messages(conversation_id, created_at)');
        await db.execute('CREATE INDEX idx_expiry ON messages(expires_at)');
        await db.execute('CREATE INDEX idx_starred ON messages(starred)');
        await _createGroupMetaTable(db);
        await _createPendingResendTable(db);
        await _createReceiptsTable(db);
        await _createPendingMediaSendsTable(db);
        await _createManualUnreadTable(db);
        await _createDeletedChatsTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 -> v2: adds the group_meta cache table for Phase 7 (group
        // chats) — see GroupService.startCaching(). Existing `messages`
        // rows are untouched by this migration.
        if (oldVersion < 2) {
          await _createGroupMetaTable(db);
        }
        // v2 -> v3: adds edited_at, used by the "edit sent message"
        // feature (see MessageRelayService.editMessage /
        // GroupMessageRelayService's shared receive path). Existing rows
        // simply get a NULL edited_at, which the UI already treats as
        // "never edited".
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
        }
        // v3 -> v4: adds pending_group_resends — see
        // GroupMessageRelayService's ContactNotUpgradedException handling.
        // Tracks group-message copies that couldn't be fanned out to a
        // specific member because they haven't published a Signal key
        // bundle yet (old app version / never signed in), so they can be
        // silently retried later once that member updates, instead of
        // repeatedly nagging the sender with a "try again" prompt that
        // would just fail the same way every time.
        if (oldVersion < 4) {
          await _createPendingResendTable(db);
        }
        // v4 -> v5: adds `message_receipts` — one row per (message, group
        // member), so a group message's read/delivered state can be
        // tracked PER RECIPIENT instead of the single shared `status`
        // column on `messages` (which — see GroupMessageRelayService's own
        // doc comment — could only ever show whichever receipt arrived
        // LAST, not a real "3 of 5 read" breakdown). 1:1 chats keep using
        // the plain `status` column unchanged; this table is additive,
        // only ever written to for group conversations (see
        // MessageRelayService._handleRow's 'receipt' case).
        if (oldVersion < 5) {
          await _createReceiptsTable(db);
        }
        // v5 -> v6: adds `pending_media_sends` — the small extra fields
        // (extension/mime/duration/ttl/recipient) needed to RETRY a
        // photo/video/voice send that failed partway through uploading,
        // without re-picking the file. The bytes themselves don't need to
        // be duplicated here: a message row is now inserted (status
        // 'sending') and its local media file saved to disk BEFORE the
        // upload starts, so a retry just re-reads that same local file.
        // See MessageRelayService.sendMediaMessage / retryMediaMessage.
        if (oldVersion < 6) {
          await _createPendingMediaSendsTable(db);
        }
        // v6 -> v7: adds `pending_media_meta` — group security setting
        // "media auto-download restrictions". When a group has that
        // turned on, an incoming photo/video isn't fetched automatically;
        // this column holds the (locally re-encrypted) key/location info
        // a later manual download needs, since the message_relay row
        // carrying the only other copy of that info gets deleted right
        // after being processed either way. NULL for every normal
        // message. See MessageRelayService._receiveMediaMessage /
        // downloadPendingMedia.
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE messages ADD COLUMN pending_media_meta TEXT');
        }
        // v7 -> v8: adds `is_view_once` / `view_once_consumed` — feature:
        // view-once media. See LocalMessage.isViewOnce/viewOnceConsumed
        // and LocalMessageStore.consumeViewOnce. Existing rows default to
        // 0/0 ("not view-once"), which is exactly right — no message sent
        // before this feature existed was ever view-once.
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE messages ADD COLUMN is_view_once INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE messages ADD COLUMN view_once_consumed INTEGER NOT NULL DEFAULT 0');
        }
        // v8 -> v9: adds `starred` — feature: starred/saved messages, a
        // personal, device-local bookmark list (never synced, never
        // visible to anyone else — see LocalMessage.starred's doc
        // comment). Existing rows default to 0 ("not starred"), which is
        // correct — nothing was starred before this feature existed.
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_starred ON messages(starred)');
        }
        // v9 -> v10: adds `is_forwarded` (feature: permission-gated message
        // forwarding — see LocalMessage.isForwarded) and the small
        // `manual_unread` table (feature: "Mark as unread"). Existing rows
        // default to is_forwarded = 0, which is exactly right — nothing
        // sent before this feature existed was a forward.
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE messages ADD COLUMN is_forwarded INTEGER NOT NULL DEFAULT 0');
          await _createManualUnreadTable(db);
        }
        // v10 -> v11: BUG FIX — "Delete chat" (home screen long-press) used
        // to only call clearConversation, which wipes this device's local
        // MESSAGES for that conversation but leaves the chat's row on the
        // home screen (it just reappears empty/as a placeholder, because
        // the shared conversation/group record in Firestore is untouched
        // and the chat list rebuilds a row from that — see
        // ChatListScreen._mergedRows). This adds `deleted_chats`, a
        // device-local list of conversationIds the person has explicitly
        // removed from THEIR OWN home screen. A conversationId in this
        // table is filtered out of the chat list entirely (see
        // ChatListScreen) until a new message arrives in it, at which
        // point [insert] below automatically clears the flag — matching
        // WhatsApp's "Delete chat" behavior (it comes back if the other
        // person messages you again, it just isn't deleted for them too).
        if (oldVersion < 11) {
          await _createDeletedChatsTable(db);
        }
      },
    );
    await purgeExpired();
  }

  static Future<void> _createManualUnreadTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS manual_unread (
        conversation_id TEXT PRIMARY KEY
      )
    ''');
  }

  static Future<void> _createDeletedChatsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_chats (
        conversation_id TEXT PRIMARY KEY
      )
    ''');
  }

  static Future<void> _createGroupMetaTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_meta (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar_url TEXT,
        member_uids TEXT NOT NULL DEFAULT '[]',
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createPendingResendTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_group_resends (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        client_id TEXT NOT NULL,
        uid TEXT NOT NULL,
        enc_payload TEXT NOT NULL,
        enc_nonce TEXT NOT NULL,
        message_type TEXT NOT NULL,
        media_path TEXT,
        reply_to_id TEXT,
        ttl_hours INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_pending_group ON pending_group_resends(group_id)');
  }

  static Future<void> _createReceiptsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_receipts (
        message_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        member_uid TEXT NOT NULL,
        status TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (message_id, member_uid)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_receipts_conv ON message_receipts(conversation_id)');
  }

  static Future<void> _createPendingMediaSendsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_media_sends (
        client_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        recipient_uid TEXT,
        is_group INTEGER NOT NULL,
        extension TEXT NOT NULL,
        mime TEXT NOT NULL,
        duration_ms INTEGER,
        ttl_hours INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Queues a group-message copy that couldn't be delivered to [uid]
  /// because they haven't published a Signal key bundle yet (see
  /// ContactNotUpgradedException) — GroupMessageRelayService retries these
  /// automatically (see [pendingGroupResends] / [removePendingGroupResend])
  /// once that member's device eventually publishes a bundle, instead of
  /// asking the sender to keep manually retrying something that can't
  /// succeed until the OTHER person updates.
  static Future<void> queuePendingGroupResend({
    required String groupId,
    required String clientId,
    required String uid,
    required String payload,
    required String messageType,
    String? mediaPath,
    String? replyToId,
    required int ttlHours,
  }) async {
    final (encPayload, nonce) = await CryptoService.encryptLocal(payload);
    await _db!.insert(
      'pending_group_resends',
      {
        'id': '${clientId}_$uid',
        'group_id': groupId,
        'client_id': clientId,
        'uid': uid,
        'enc_payload': encPayload,
        'enc_nonce': nonce,
        'message_type': messageType,
        'media_path': mediaPath,
        'reply_to_id': replyToId,
        'ttl_hours': ttlHours,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All queued resend attempts for one group, decrypted — read by
  /// GroupMessageRelayService.retryPendingResends.
  static Future<List<PendingGroupResend>> pendingGroupResends(String groupId) async {
    final rows = await _db!.query('pending_group_resends', where: 'group_id = ?', whereArgs: [groupId]);
    final result = <PendingGroupResend>[];
    for (final r in rows) {
      final payload = await CryptoService.decryptLocal(r['enc_payload'] as String, r['enc_nonce'] as String);
      result.add(PendingGroupResend(
        id: r['id'] as String,
        groupId: r['group_id'] as String,
        clientId: r['client_id'] as String,
        uid: r['uid'] as String,
        payload: payload,
        messageType: r['message_type'] as String,
        mediaPath: r['media_path'] as String?,
        replyToId: r['reply_to_id'] as String?,
        ttlHours: r['ttl_hours'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      ));
    }
    return result;
  }

  static Future<void> removePendingGroupResend(String id) async {
    await _db!.delete('pending_group_resends', where: 'id = ?', whereArgs: [id]);
  }

  /// All group ids with at least one queued resend — used at app startup
  /// to sweep every group, not just whichever one the person happens to
  /// open first (see GroupService.retryAllPendingResends).
  static Future<List<String>> groupIdsWithPendingResends() async {
    final rows = await _db!.query('pending_group_resends', columns: ['group_id'], distinct: true);
    return rows.map((r) => r['group_id'] as String).toList();
  }

  // ---- group metadata cache (see GroupService.startCaching) ------------

  static Future<void> upsertGroupMeta({
    required String id,
    required String name,
    String? avatarUrl,
    required List<String> memberUids,
  }) async {
    await _db!.insert('group_meta', {
      'id': id,
      'name': name,
      'avatar_url': avatarUrl,
      'member_uids': jsonEncode(memberUids),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifySummaries();
  }

  static Future<List<String>> cachedGroupMemberUids(String groupId) async {
    final rows = await _db!.query('group_meta', columns: ['member_uids'], where: 'id = ?', whereArgs: [groupId], limit: 1);
    if (rows.isEmpty) return [];
    return List<String>.from(jsonDecode(rows.first['member_uids'] as String));
  }

  static Future<void> removeGroupMeta(String groupId) async {
    await _db!.delete('group_meta', where: 'id = ?', whereArgs: [groupId]);
    _notifySummaries();
  }

  static Future<LocalMessage> insert({
    required String id,
    required String conversationId,
    required String peerUid,
    required String senderUid,
    required bool isMine,
    required String text,
    String messageType = 'text',
    String? mediaPath,
    String? replyToId,
    String status = 'sent',
    required DateTime createdAt,
    DateTime? expiresAt,
    Map<String, dynamic>? pendingMediaMeta,
    bool isViewOnce = false,
    bool isForwarded = false,
  }) async {
    final (encText, nonce) = await CryptoService.encryptLocal(text);
    String? encPendingMeta;
    if (pendingMediaMeta != null) {
      final (metaCipher, metaNonce) = await CryptoService.encryptLocal(jsonEncode(pendingMediaMeta));
      encPendingMeta = jsonEncode({'c': metaCipher, 'n': metaNonce});
    }
    await _db!.insert('messages', {
      'id': id,
      'conversation_id': conversationId,
      'peer_uid': peerUid,
      'sender_uid': senderUid,
      'is_mine': isMine ? 1 : 0,
      'enc_text': encText,
      'enc_nonce': nonce,
      'message_type': messageType,
      'media_path': mediaPath,
      'reply_to_id': replyToId,
      'reactions': '{}',
      'status': status,
      'created_at': createdAt.millisecondsSinceEpoch,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
      'edited_at': null,
      'pending_media_meta': encPendingMeta,
      'is_view_once': isViewOnce ? 1 : 0,
      'view_once_consumed': 0,
      'starred': 0,
      'is_forwarded': isForwarded ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Bug fix: a new message (sent OR received) in a conversation the
    // person previously "deleted" from their home screen un-deletes it —
    // it has real new content again, so it belongs back on the list. See
    // markChatDeletedLocally's doc comment.
    await _clearDeletedFlagQuietly(conversationId);

    final msg = LocalMessage(
      id: id,
      conversationId: conversationId,
      peerUid: peerUid,
      senderUid: senderUid,
      isMine: isMine,
      text: text,
      messageType: messageType,
      mediaPath: mediaPath,
      replyToId: replyToId,
      status: status,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hasPendingMedia: encPendingMeta != null,
      isViewOnce: isViewOnce,
      isForwarded: isForwarded,
    );
    _notifyConversation(conversationId);
    _notifySummaries();
    return msg;
  }

  static Future<void> setStatus(String id, String status) async {
    final row = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (row.isEmpty) return;
    await _db!.update('messages', {'status': status}, where: 'id = ?', whereArgs: [id]);
    _notifyConversation(row.first['conversation_id'] as String);
  }

  // ---- per-member group read receipts (Feature: accurate group receipts) ----

  /// Records that [memberUid] has delivered/read the group message
  /// [messageId] — called from MessageRelayService._handleRow's 'receipt'
  /// case for GROUP conversations only (1:1 chats keep using [setStatus]
  /// unchanged). Never downgrades an existing 'read' back to 'delivered' —
  /// receipts can arrive out of order over an unreliable connection, and a
  /// stale 'delivered' retry landing after the real 'read' shouldn't undo
  /// it in the UI.
  static Future<void> setGroupReceipt({
    required String conversationId,
    required String messageId,
    required String memberUid,
    required String status,
  }) async {
    final existing = await _db!.query(
      'message_receipts',
      where: 'message_id = ? AND member_uid = ?',
      whereArgs: [messageId, memberUid],
      limit: 1,
    );
    if (existing.isNotEmpty && existing.first['status'] == 'read' && status != 'read') return;
    await _db!.insert(
      'message_receipts',
      {
        'message_id': messageId,
        'conversation_id': conversationId,
        'member_uid': memberUid,
        'status': status,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyGroupReceipts(conversationId);
  }

  static Future<Map<String, Map<String, String>>> _loadGroupReceipts(String conversationId) async {
    final rows = await _db!.query('message_receipts', where: 'conversation_id = ?', whereArgs: [conversationId]);
    final result = <String, Map<String, String>>{};
    for (final r in rows) {
      final byMember = result.putIfAbsent(r['message_id'] as String, () => {});
      byMember[r['member_uid'] as String] = r['status'] as String;
    }
    return result;
  }

  static void _notifyGroupReceipts(String conversationId, [int attempt = 0]) {
    final controller = _receiptControllers[conversationId];
    if (controller == null) return;
    _loadGroupReceipts(conversationId).then((m) {
      if (!controller.isClosed) controller.add(m);
    }).catchError((Object e) {
      if (attempt >= 5) return;
      Future.delayed(Duration(milliseconds: 300 * (attempt + 1)), () => _notifyGroupReceipts(conversationId, attempt + 1));
    });
  }

  /// Emits `{messageId: {memberUid: status}}` for every message in
  /// [conversationId] whenever a receipt changes — GroupChatScreen uses
  /// this alongside [watchConversation] to render a real "Read 3/5"
  /// indicator on its own sent messages instead of a single check mark.
  static Stream<Map<String, Map<String, String>>> watchGroupReceipts(String conversationId) {
    final controller = _receiptControllers.putIfAbsent(
      conversationId,
      () => StreamController<Map<String, Map<String, String>>>.broadcast(onCancel: () {
        _receiptControllers.remove(conversationId);
      }),
    );
    _notifyGroupReceipts(conversationId);
    return controller.stream;
  }

  // ---- pending media sends (Feature: upload progress + retry) ----------

  /// Saved right after a photo/video/voice message's local row+file are
  /// created but BEFORE the upload starts (see
  /// MessageRelayService.sendMediaMessage) — holds exactly the extra
  /// fields a retry needs that aren't already sitting in the `messages`
  /// row itself (caption/media path are read back via [getById]).
  /// Removed again once the send finally succeeds; left in place on
  /// failure so [retryMediaMessage] can pick it up later.
  static Future<void> savePendingMediaSend({
    required String clientId,
    required String conversationId,
    String? recipientUid,
    required bool isGroup,
    required String extension,
    required String mime,
    int? durationMs,
    required int ttlHours,
  }) async {
    await _db!.insert(
      'pending_media_sends',
      {
        'client_id': clientId,
        'conversation_id': conversationId,
        'recipient_uid': recipientUid,
        'is_group': isGroup ? 1 : 0,
        'extension': extension,
        'mime': mime,
        'duration_ms': durationMs,
        'ttl_hours': ttlHours,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<PendingMediaSend?> getPendingMediaSend(String clientId) async {
    final rows = await _db!.query('pending_media_sends', where: 'client_id = ?', whereArgs: [clientId], limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return PendingMediaSend(
      clientId: r['client_id'] as String,
      conversationId: r['conversation_id'] as String,
      recipientUid: r['recipient_uid'] as String?,
      isGroup: (r['is_group'] as int) == 1,
      extension: r['extension'] as String,
      mime: r['mime'] as String,
      durationMs: r['duration_ms'] as int?,
      ttlHours: r['ttl_hours'] as int,
    );
  }

  static Future<void> removePendingMediaSend(String clientId) async {
    await _db!.delete('pending_media_sends', where: 'client_id = ?', whereArgs: [clientId]);
  }

  /// Every message currently sitting in 'failed' status, across every
  /// conversation — used to offer a "retry all" action and to
  /// automatically retry once connectivity comes back (see
  /// ConversationService/ChatListScreen wiring, if enabled).
  static Future<List<String>> failedMediaClientIds() async {
    final rows = await _db!.query('messages', columns: ['id'], where: "status = 'failed'");
    return rows.map((r) => r['id'] as String).toList();
  }

  static Future<void> setReaction(String id, String uid, String? emoji) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final reactions = Map<String, dynamic>.from(jsonDecode(rows.first['reactions'] as String));
    if (emoji == null) {
      reactions.remove(uid);
    } else {
      reactions[uid] = emoji;
    }
    await _db!.update('messages', {'reactions': jsonEncode(reactions)}, where: 'id = ?', whereArgs: [id]);
    _notifyConversation(rows.first['conversation_id'] as String);
  }

  /// Applies an edit to an existing message's text — used both when WE
  /// edit our own sent message (see MessageRelayService.editMessage /
  /// GroupMessageRelayService's edit fan-out) and when an edit arrives
  /// FROM a peer for a message they sent us. Re-encrypts under the same
  /// local-at-rest scheme as a normal insert; sets `edited_at` so the UI
  /// can show an "(edited)" label. No-ops quietly if the message no
  /// longer exists locally (e.g. already deleted) — same "leave it, don't
  /// throw" approach the rest of this store takes for stale references.
  static Future<void> editMessage(String id, String newText) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final (encText, nonce) = await CryptoService.encryptLocal(newText);
    await _db!.update(
      'messages',
      {'enc_text': encText, 'enc_nonce': nonce, 'edited_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyConversation(rows.first['conversation_id'] as String);
    _notifySummaries();
  }

  /// Group security setting: media auto-download restrictions. Decrypts
  /// and returns the key/location info [MessageRelayService._receiveMediaMessage]
  /// stashed instead of downloading, so [MessageRelayService.downloadPendingMedia]
  /// can fetch it on demand. Null if this message has no pending download
  /// (either it's not a media message, or it already downloaded normally).
  static Future<Map<String, dynamic>?> getPendingMediaMeta(String id) async {
    final rows = await _db!.query('messages', columns: ['pending_media_meta'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final raw = rows.first['pending_media_meta'] as String?;
    if (raw == null) return null;
    final wrapper = jsonDecode(raw) as Map<String, dynamic>;
    final json = await CryptoService.decryptLocal(wrapper['c'] as String, wrapper['n'] as String);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Completes a manual download: sets the real local media path and
  /// caption, and clears the pending-download meta (its job is done —
  /// nothing sensitive should linger in it longer than necessary).
  static Future<void> resolvePendingMedia(String id, String mediaPath, String caption) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final (encText, nonce) = await CryptoService.encryptLocal(caption);
    await _db!.update(
      'messages',
      {'media_path': mediaPath, 'enc_text': encText, 'enc_nonce': nonce, 'pending_media_meta': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyConversation(rows.first['conversation_id'] as String);
  } // resolvePendingMedia

  /// Single-row lookup, decrypted — used by the "Resend to X" group-send
  /// retry action (it needs the original text again) and by the edit flow
  /// (to check the original send time against the edit window).
  static Future<LocalMessage?> getById(String id) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _rowToMessage(rows.first);
  }

  /// In-memory substring search across one conversation's ALREADY-STORED,
  /// already-decrypted messages — cheap because message text lives fully
  /// decrypted-on-demand on this device already (see the class doc
  /// comment), so there's no server-side index to build or maintain for
  /// this. Case-insensitive; matches message text only (not media
  /// captions of a different type, though captions are stored in the same
  /// `text` column so they're naturally included too). Returned oldest
  /// first, same order as watchConversation, so the search screen can
  /// show results in the same chronological order as the chat itself.
  static Future<List<LocalMessage>> searchConversation(String conversationId, String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return [];
    final all = await _loadConversation(conversationId);
    return all.where((m) => m.text.toLowerCase().contains(needle)).toList();
  }

  /// Feature: global search across all chats. Same in-memory substring
  /// approach as [searchConversation], just over every conversation
  /// instead of one — still no server-side index (there's nothing for a
  /// server to index; it never sees plaintext at all). Capped at 300
  /// matches, most recent first, so a very broad query against years of
  /// history can't stall the UI decrypting thousands of rows just to
  /// throw most of them away unread.
  static Future<List<LocalMessage>> searchAll(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return [];
    final rows = await _db!.query('messages', orderBy: 'created_at DESC', limit: 2000);
    final results = <LocalMessage>[];
    for (final r in rows) {
      final msg = await _rowToMessage(r);
      if (msg.text.toLowerCase().contains(needle)) {
        results.add(msg);
        if (results.length >= 300) break;
      }
    }
    return results;
  }

  /// Feature: starred/saved messages. Device-local only — see
  /// LocalMessage.starred's doc comment for why nothing here ever talks
  /// to the relay or to Firestore.
  static Future<void> toggleStar(String id) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final currentlyStarred = (rows.first['starred'] as int? ?? 0) == 1;
    await _db!.update('messages', {'starred': currentlyStarred ? 0 : 1}, where: 'id = ?', whereArgs: [id]);
    _notifyConversation(rows.first['conversation_id'] as String);
    _notifyStarred();
  }

  static Future<void> setStarredBulk(List<String> ids, bool starred) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db!.update('messages', {'starred': starred ? 1 : 0}, where: 'id IN ($placeholders)', whereArgs: ids);
    final rows = await _db!.rawQuery('SELECT DISTINCT conversation_id FROM messages WHERE id IN ($placeholders)', ids);
    for (final r in rows) {
      _notifyConversation(r['conversation_id'] as String);
    }
    _notifyStarred();
  }

  static final _starredController = StreamController<List<LocalMessage>>.broadcast();

  static Future<void> _notifyStarred() async {
    if (_starredController.isClosed) return;
    final rows = await _db!.query('messages', where: 'starred = 1', orderBy: 'created_at DESC');
    final result = <LocalMessage>[];
    for (final r in rows) {
      result.add(await _rowToMessage(r));
    }
    _starredController.add(result);
  }

  static Stream<List<LocalMessage>> watchStarred() {
    _notifyStarred();
    return _starredController.stream;
  }

  /// Feature: "jump to unread" button. Called ONCE, right when a chat
  /// screen opens, BEFORE [markConversationRead] has a chance to run for
  /// this visit — the whole point is capturing what was unread the
  /// moment this chat was opened, as a fixed target to scroll back to,
  /// not a live "still unread right now" value that would change out
  /// from under the button the instant the messages currently on screen
  /// get marked read.
  static Future<String?> getFirstUnreadId(String conversationId) async {
    final rows = await _db!.query(
      'messages',
      columns: ['id'],
      where: "conversation_id = ? AND is_mine = 0 AND status != 'read'",
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as String;
  }

  /// Feature: mute by keyword. Used ONLY from main.dart's foreground FCM
  /// handler, to check the most-recently-received message's REAL,
  /// already-decrypted text against the muted-keyword list before
  /// showing a local notification for it. See KeywordMuteService's own
  /// doc comment for why this is foreground-only and best-effort — the
  /// push payload itself never contains real text (this app's relay
  /// never has any plaintext to put there), so this is racing against
  /// whichever arrives/finishes first, the realtime decrypt-and-store or
  /// the FCM message. Returns null if nothing's been stored for this
  /// conversation yet (i.e. the race was lost) — the caller treats that
  /// as "can't tell, so don't suppress the notification".
  static Future<LocalMessage?> getLatestMessage(String conversationId) async {
    final rows = await _db!.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToMessage(rows.first);
  }

  /// Feature: multi-select + bulk actions. Deletes several messages in
  /// one pass — just [deleteMessage] called per id, kept as its own
  /// method so callers (the bulk-delete confirmation dialog) only need
  /// one call and one round of conversation/summary notifications
  /// instead of one per message.
  static Future<void> deleteMessages(List<String> ids) async {
    for (final id in ids) {
      await deleteMessage(id);
    }
  }

  static Future<void> deleteMessage(String id) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    await _db!.delete('messages', where: 'id = ?', whereArgs: [id]);
    // BUGFIX: media files used to be orphaned on disk forever whenever
    // their message was deleted (delete-for-me, delete-for-everyone, or
    // expiry) — only the SQLite row was removed, never the actual
    // image/video/voice file it pointed to.
    await LocalMediaFiles.delete(rows.first['media_path'] as String?);
    await _db!.delete('message_receipts', where: 'message_id = ?', whereArgs: [id]);
    await _db!.delete('pending_media_sends', where: 'client_id = ?', whereArgs: [id]);
    _notifyConversation(rows.first['conversation_id'] as String);
    _notifyGroupReceipts(rows.first['conversation_id'] as String);
    _notifySummaries();
    _notifyStarred();
  }

  /// Feature: view-once media. Called when the RECIPIENT closes the
  /// full-screen viewer for a view-once photo/video (see
  /// widgets/view_once_media_screen.dart) — permanently deletes the media
  /// file from disk and clears media_path, and flips view_once_consumed
  /// so it can never be opened again. No-op (and safe to call) if the
  /// message isn't view-once, was already consumed, or has no media
  /// (e.g. it was sent by ME — the sender's own copy is never consumed,
  /// see ChatDetailScreen/GroupChatScreen, which only ever call this for
  /// a message where isMine is false).
  static Future<void> consumeViewOnce(String id) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final row = rows.first;
    if ((row['is_view_once'] as int? ?? 0) != 1) return;
    if ((row['view_once_consumed'] as int? ?? 0) == 1) return;
    final mediaPath = row['media_path'] as String?;
    await _db!.update(
      'messages',
      {'view_once_consumed': 1, 'media_path': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    await LocalMediaFiles.delete(mediaPath);
    _notifyConversation(row['conversation_id'] as String);
    _notifySummaries();
  }

  static Future<void> clearConversation(String conversationId) async {
    final rows = await _db!.query('messages', columns: ['media_path'], where: 'conversation_id = ?', whereArgs: [conversationId]);
    await _db!.delete('messages', where: 'conversation_id = ?', whereArgs: [conversationId]);
    for (final r in rows) {
      await LocalMediaFiles.delete(r['media_path'] as String?);
    }
    await _db!.delete('message_receipts', where: 'conversation_id = ?', whereArgs: [conversationId]);
    await _db!.delete('pending_media_sends', where: 'conversation_id = ?', whereArgs: [conversationId]);
    await setManualUnread(conversationId, false);
    _notifyConversation(conversationId);
    _notifyGroupReceipts(conversationId);
    _notifySummaries();
  }

  // ---- "Mark as unread" (Feature) ------------------------------------

  /// Feature: "Mark as unread". A purely local, cosmetic reminder — "I've
  /// read this, but I want to come back to it". It shows a dot on the chat
  /// row and counts as 1 toward the app-icon badge, and it clears the moment
  /// the chat is opened again (see [markConversationRead]).
  ///
  /// It deliberately never touches any message's real read status and never
  /// sends anything to the relay, so it can't send or withdraw a read
  /// receipt — the other person has no way to tell it was ever set.
  static Future<void> setManualUnread(String conversationId, bool value) async {
    if (value) {
      await _db!.insert(
        'manual_unread',
        {'conversation_id': conversationId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      final removed = await _db!.delete('manual_unread', where: 'conversation_id = ?', whereArgs: [conversationId]);
      if (removed == 0) return; // nothing changed, so nothing to announce
    }
    _notifyManualUnread();
  }

  static Future<Set<String>> _loadManualUnread() async {
    final rows = await _db!.query('manual_unread', columns: ['conversation_id']);
    return rows.map((r) => r['conversation_id'] as String).toSet();
  }

  static void _notifyManualUnread() {
    _loadManualUnread().then((ids) {
      if (!_manualUnreadController.isClosed) _manualUnreadController.add(ids);
    }).catchError((Object e) {});
  }

  /// Emits the full set of manually-unread conversation ids whenever it
  /// changes (and once right away with the current set).
  static Stream<Set<String>> watchManualUnread() {
    _notifyManualUnread();
    return _manualUnreadController.stream;
  }

  // ---- "Delete chat" (Bug fix / feature) ------------------------------
  //
  // WhatsApp/Instagram-style "Delete chat": removes the chat's ROW from
  // this device's home screen, not just its message content (that part —
  // wiping the actual messages — is still clearForConversation/
  // clearConversation, unchanged). See deleted_chats' table comment above
  // for the full story. This is device-local only: it never touches the
  // shared Firestore conversation/group document, so it can't affect
  // pinned/muted/archived state or anything else for the OTHER person.

  /// Call together with [clearConversation] when the person picks "Delete
  /// chat" from the home screen's long-press menu (see ChatListScreen).
  /// Kept separate from clearConversation itself because clearConversation
  /// is ALSO used by "Clear chat" from inside an open chat (see
  /// MessageRelayService.clearForBoth) and by the "clear on exit"
  /// ephemeral-view feature (ChatDetailScreen.dispose) — neither of those
  /// should remove the chat from the home screen, only "Delete chat"
  /// should.
  static Future<void> markChatDeletedLocally(String conversationId) async {
    await _db!.insert(
      'deleted_chats',
      {'conversation_id': conversationId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyDeletedChats();
    _notifySummaries();
  }

  /// Internal: silently clears the "deleted" flag (no-op if it wasn't
  /// set) — called from [insert] so a fresh incoming/outgoing message
  /// brings a deleted chat back, same as WhatsApp.
  static Future<void> _clearDeletedFlagQuietly(String conversationId) async {
    final removed = await _db!.delete('deleted_chats', where: 'conversation_id = ?', whereArgs: [conversationId]);
    if (removed > 0) _notifyDeletedChats();
  }

  static Future<Set<String>> _loadDeletedChats() async {
    final rows = await _db!.query('deleted_chats', columns: ['conversation_id']);
    return rows.map((r) => r['conversation_id'] as String).toSet();
  }

  static void _notifyDeletedChats() {
    _loadDeletedChats().then((ids) {
      if (!_deletedChatsController.isClosed) _deletedChatsController.add(ids);
    }).catchError((Object e) {});
  }

  /// Emits the full set of locally-deleted conversation ids whenever it
  /// changes (and once right away with the current set). ChatListScreen
  /// filters these out of the home screen entirely.
  static Stream<Set<String>> watchDeletedChats() {
    _notifyDeletedChats();
    return _deletedChatsController.stream;
  }

  static Future<void> markConversationRead(String conversationId) async {
    // Opening a chat also clears a manual "Mark as unread" flag on it.
    await setManualUnread(conversationId, false);
    await _db!.update(
      'messages',
      {'status': 'read'},
      where: 'conversation_id = ? AND is_mine = 0 AND status != ?',
      whereArgs: [conversationId, 'read'],
    );
    _notifyConversation(conversationId);
    _notifySummaries();
  }

  static Future<void> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await _db!.query('messages', columns: ['conversation_id', 'media_path'], where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    if (rows.isEmpty) return;
    await _db!.delete('messages', where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    final affected = <String>{};
    for (final r in rows) {
      affected.add(r['conversation_id'] as String);
      await LocalMediaFiles.delete(r['media_path'] as String?);
    }
    for (final c in affected) {
      _notifyConversation(c);
    }
    _notifySummaries();
  }

  /// Wipes every local message and clears out (without closing) any open
  /// per-conversation stream subscriptions — used when a different account
  /// signs in on this device (see SessionService). The messages would be
  /// undecryptable garbage anyway once the local storage key is wiped
  /// alongside this, so they're cleared outright rather than left as
  /// orphaned rows. Also wipes the group_meta cache — it belonged to the
  /// previous account's groups.
  static Future<void> resetForNewUser() async {
    await _db!.delete('messages');
    await _db!.delete('group_meta');
    await _db!.delete('message_receipts');
    await _db!.delete('pending_media_sends');
    await _db!.delete('manual_unread');
    _notifyManualUnread();
    await _db!.delete('deleted_chats');
    _notifyDeletedChats();
    // Feature: locked media vault — it belongs to the account that set it up,
    // so a different account signing in on this phone (or an account being
    // deleted) wipes it too, exactly like everything else here.
    await MediaVaultService.instance.wipeAll();
    await LocalMediaFiles.deleteAll();
    for (final controller in _convoControllers.values) {
      if (!controller.isClosed) controller.add([]);
    }
    for (final controller in _receiptControllers.values) {
      if (!controller.isClosed) controller.add({});
    }
    _notifySummaries();
  }

  static Future<LocalMessage> _rowToMessage(Map<String, dynamic> r) async {
    final text = await CryptoService.decryptLocal(r['enc_text'] as String, r['enc_nonce'] as String);
    return LocalMessage(
      id: r['id'] as String,
      conversationId: r['conversation_id'] as String,
      peerUid: r['peer_uid'] as String,
      senderUid: r['sender_uid'] as String,
      isMine: (r['is_mine'] as int) == 1,
      text: text,
      messageType: r['message_type'] as String,
      mediaPath: r['media_path'] as String?,
      replyToId: r['reply_to_id'] as String?,
      reactions: Map<String, String>.from(jsonDecode(r['reactions'] as String)),
      status: r['status'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      expiresAt: r['expires_at'] != null ? DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int) : null,
      editedAt: r['edited_at'] != null ? DateTime.fromMillisecondsSinceEpoch(r['edited_at'] as int) : null,
      hasPendingMedia: r['pending_media_meta'] != null,
      isViewOnce: (r['is_view_once'] as int? ?? 0) == 1,
      viewOnceConsumed: (r['view_once_consumed'] as int? ?? 0) == 1,
      starred: (r['starred'] as int? ?? 0) == 1,
      isForwarded: (r['is_forwarded'] as int? ?? 0) == 1,
    );
  }

  /// Feature: per-chat media/links browser. Thin public wrapper around
  /// the same already-private [_loadConversation] load used for opening
  /// a chat normally — the browser screen does its own client-side
  /// filtering into Media / Voice / Links tabs from this one list rather
  /// than three separate queries, since it's already the full
  /// conversation and there's no meaningful cost difference for a single
  /// chat's message count.
  static Future<List<LocalMessage>> loadConversationForBrowsing(String conversationId) => _loadConversation(conversationId);

  static Future<List<LocalMessage>> _loadConversation(String conversationId) async {
    final rows = await _db!.query('messages', where: 'conversation_id = ?', whereArgs: [conversationId], orderBy: 'created_at ASC');
    final result = <LocalMessage>[];
    for (final r in rows) {
      result.add(await _rowToMessage(r));
    }
    return result;
  }

  /// Retries with backoff instead of dropping the update on the floor.
  /// Capped at 5 attempts so a genuinely bad row can't retry forever.
  static void _notifyConversation(String conversationId, [int attempt = 0]) {
    final controller = _convoControllers[conversationId];
    if (controller == null) return;
    _loadConversation(conversationId).then((list) {
      if (!controller.isClosed) controller.add(list);
    }).catchError((Object e) {
      if (attempt >= 5) return;
      Future.delayed(Duration(milliseconds: 300 * (attempt + 1)), () => _notifyConversation(conversationId, attempt + 1));
    });
  }

  static Stream<List<LocalMessage>> watchConversation(String conversationId) {
    final controller = _convoControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<LocalMessage>>.broadcast(onCancel: () {
        _convoControllers.remove(conversationId);
      }),
    );
    _notifyConversation(conversationId);
    return controller.stream;
  }

  static Future<List<ConversationSummary>> _loadSummaries() async {
    final rows = await _db!.rawQuery('''
      SELECT m1.conversation_id, m1.peer_uid, m1.enc_text, m1.enc_nonce, m1.created_at,
        gm.name AS group_name, gm.avatar_url AS group_avatar_url,
        (SELECT COUNT(*) FROM messages m2
          WHERE m2.conversation_id = m1.conversation_id AND m2.is_mine = 0 AND m2.status != 'read') AS unread
      FROM messages m1
      LEFT JOIN group_meta gm ON gm.id = m1.conversation_id
      WHERE m1.created_at = (SELECT MAX(created_at) FROM messages m3 WHERE m3.conversation_id = m1.conversation_id)
      GROUP BY m1.conversation_id
      ORDER BY m1.created_at DESC
    ''');
    final result = <ConversationSummary>[];
    for (final r in rows) {
      final text = await CryptoService.decryptLocal(r['enc_text'] as String, r['enc_nonce'] as String);
      final conversationId = r['conversation_id'] as String;
      result.add(ConversationSummary(
        conversationId: conversationId,
        peerUid: r['peer_uid'] as String,
        lastText: text,
        lastAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        unreadCount: r['unread'] as int,
        isGroup: conversationId.startsWith(_groupPrefix),
        groupName: r['group_name'] as String?,
        groupAvatarUrl: r['group_avatar_url'] as String?,
      ));
    }
    return result;
  }

  static void _notifySummaries([int attempt = 0]) {
    _loadSummaries().then((list) {
      if (!_summaryController.isClosed) _summaryController.add(list);
    }).catchError((Object e) {
      if (attempt >= 5) return;
      Future.delayed(Duration(milliseconds: 300 * (attempt + 1)), () => _notifySummaries(attempt + 1));
    });
  }

  static Stream<List<ConversationSummary>> watchSummaries() {
    _notifySummaries();
    return _summaryController.stream;
  }
}
