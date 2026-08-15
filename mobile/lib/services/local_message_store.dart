import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/local_message.dart';
import 'crypto_service.dart';

/// On-device store for message content. This is now the ONLY place message
/// text lives long-term — Supabase only ever holds a message transiently in
/// transit, and Firestore never sees message content at all. Every row's
/// `enc_text` column is AES-GCM ciphertext under a device-local key (see
/// CryptoService.encryptLocal) — plaintext only ever exists in memory.
class LocalMessageStore {
  static Database? _db;
  static final Map<String, StreamController<List<LocalMessage>>> _convoControllers = {};
  static final _summaryController = StreamController<List<ConversationSummary>>.broadcast();

  static Future<void> init() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'nwisp_messages.db');
    _db = await openDatabase(
      path,
      version: 1,
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
      },
    );
    await purgeExpired();
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
    _notifyConversation(rows.first['conversation_id'] as String);
    _notifySummaries();
  }

  static Future<void> clearConversation(String conversationId) async {
    await _db!.delete('messages', where: 'conversation_id = ?', whereArgs: [conversationId]);
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
    final rows = await _db!.query('messages', columns: ['conversation_id'], where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    if (rows.isEmpty) return;
    await _db!.delete('messages', where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    final affected = rows.map((r) => r['conversation_id'] as String).toSet();
    for (final c in affected) {
      _notifyConversation(c);
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

  static void _notifyConversation(String conversationId) {
    final controller = _convoControllers[conversationId];
    if (controller == null) return;
    _loadConversation(conversationId).then((list) {
      if (!controller.isClosed) controller.add(list);
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
      SELECT conversation_id, peer_uid, enc_text, enc_nonce, created_at,
        (SELECT COUNT(*) FROM messages m2
          WHERE m2.conversation_id = m1.conversation_id AND m2.is_mine = 0 AND m2.status != 'read') AS unread
      FROM messages m1
      WHERE created_at = (SELECT MAX(created_at) FROM messages m3 WHERE m3.conversation_id = m1.conversation_id)
      GROUP BY conversation_id
      ORDER BY created_at DESC
    ''');
    final result = <ConversationSummary>[];
    for (final r in rows) {
      final text = await CryptoService.decryptLocal(r['enc_text'] as String, r['enc_nonce'] as String);
      result.add(ConversationSummary(
        conversationId: r['conversation_id'] as String,
        peerUid: r['peer_uid'] as String,
        lastText: text,
        lastAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        unreadCount: r['unread'] as int,
      ));
    }
    return result;
  }

  static void _notifySummaries() {
    _loadSummaries().then((list) {
      if (!_summaryController.isClosed) _summaryController.add(list);
    });
  }

  static Stream<List<ConversationSummary>> watchSummaries() {
    _notifySummaries();
    return _summaryController.stream;
  }
}
