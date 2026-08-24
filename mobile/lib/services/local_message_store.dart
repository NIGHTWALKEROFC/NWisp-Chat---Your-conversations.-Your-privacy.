import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/local_message.dart';
import 'crypto_service.dart';
import 'local_media_files.dart';

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

  static const _groupPrefix = 'group_';

  static Future<void> init() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'nwisp_messages.db');
    _db = await openDatabase(
      path,
      version: 2,
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
            expires_at INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_conv ON messages(conversation_id, created_at)');
        await db.execute('CREATE INDEX idx_expiry ON messages(expires_at)');
        await _createGroupMetaTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 -> v2: adds the group_meta cache table for Phase 7 (group
        // chats) — see GroupService.startCaching(). Existing `messages`
        // rows are untouched by this migration.
        if (oldVersion < 2) {
          await _createGroupMetaTable(db);
        }
      },
    );
    await purgeExpired();
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
  }) async {
    final (encText, nonce) = await CryptoService.encryptLocal(text);
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
    }, conflictAlgorithm: ConflictAlgorithm.replace);

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

  static Future<void> deleteMessage(String id) async {
    final rows = await _db!.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    await _db!.delete('messages', where: 'id = ?', whereArgs: [id]);
    // BUGFIX: media files used to be orphaned on disk forever whenever
    // their message was deleted (delete-for-me, delete-for-everyone, or
    // expiry) — only the SQLite row was removed, never the actual
    // image/video/voice file it pointed to.
    await LocalMediaFiles.delete(rows.first['media_path'] as String?);
    _notifyConversation(rows.first['conversation_id'] as String);
    _notifySummaries();
  }

  static Future<void> clearConversation(String conversationId) async {
    final rows = await _db!.query('messages', columns: ['media_path'], where: 'conversation_id = ?', whereArgs: [conversationId]);
    await _db!.delete('messages', where: 'conversation_id = ?', whereArgs: [conversationId]);
    for (final r in rows) {
      await LocalMediaFiles.delete(r['media_path'] as String?);
    }
    _notifyConversation(conversationId);
    _notifySummaries();
  }

  static Future<void> markConversationRead(String conversationId) async {
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
    await LocalMediaFiles.deleteAll();
    for (final controller in _convoControllers.values) {
      if (!controller.isClosed) controller.add([]);
    }
    _notifySummaries();
  }

  static Future<List<LocalMessage>> _loadConversation(String conversationId) async {
    final rows = await _db!.query('messages', where: 'conversation_id = ?', whereArgs: [conversationId], orderBy: 'created_at ASC');
    final result = <LocalMessage>[];
    for (final r in rows) {
      final text = await CryptoService.decryptLocal(r['enc_text'] as String, r['enc_nonce'] as String);
      result.add(LocalMessage(
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
      ));
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
