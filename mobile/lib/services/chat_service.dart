import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'media_service.dart';

class ChatService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  static const ttlHours = 24;

  Stream<QuerySnapshot<Map<String, dynamic>>> messageStream(String conversationId) {
    return _db
        .collection('conversations').doc(conversationId)
        .collection('messages')
        .orderBy('createdAt')
        .snapshots();
  }

  Future<void> sendMessage({
    required String conversationId,
    required String ciphertext,
    String messageType = 'text',
    String? mediaPath,
    String? replyToId,
    int? ttlHours,
  }) async {
    final uid = _auth.currentUser!.uid;
    final now = DateTime.now();
    await _db
        .collection('conversations').doc(conversationId)
        .collection('messages').add({
      'senderId': uid,
      'ciphertext': ciphertext,
      'messageType': messageType,
      'mediaPath': mediaPath,
      'replyToId': replyToId,
      'reactions': <String, String>{},
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(Duration(hours: ttlHours ?? ChatService.ttlHours))),
      'deliveredTo': <String>[],
      'readBy': <String>[],
    });
  }

  Future<void> sendMediaMessage({
    required String conversationId,
    required File file,
    required String ciphertext,
    required String messageType,
  }) async {
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_${file.path.split('/').last}';
    final path = 'chat_media/$conversationId/$fileName';
    await MediaService.uploadFile(file, 'media', path);
    await sendMessage(
      conversationId: conversationId,
      ciphertext: ciphertext,
      messageType: messageType,
      mediaPath: path,
    );
  }

  Future<void> markRead(String conversationId, String messageId) async {
    final uid = _auth.currentUser!.uid;
    await _db
        .collection('conversations').doc(conversationId)
        .collection('messages').doc(messageId)
        .update({'readBy': FieldValue.arrayUnion([uid])});
  }

  /// Sets or clears the current user's emoji reaction on a message.
  /// Passing null removes their reaction.
  Future<void> setReaction(String conversationId, String messageId, String? emoji) async {
    final uid = _auth.currentUser!.uid;
    final ref = _db
        .collection('conversations').doc(conversationId)
        .collection('messages').doc(messageId);
    if (emoji == null) {
      await ref.update({'reactions.$uid': FieldValue.delete()});
    } else {
      await ref.update({'reactions.$uid': emoji});
    }
  }

  /// Writes a short-lived typing flag for the current user. It's fine for
  /// this to be called on every keystroke — Firestore writes are cheap and
  /// the UI debounces on the reading side by checking `updatedAt` recency.
  Future<void> setTyping(String conversationId, bool isTyping) async {
    final uid = _auth.currentUser!.uid;
    await _db
        .collection('conversations').doc(conversationId)
        .collection('typing').doc(uid)
        .set({'isTyping': isTyping, 'updatedAt': FieldValue.serverTimestamp()});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> typingStream(String conversationId) {
    return _db
        .collection('conversations').doc(conversationId)
        .collection('typing')
        .snapshots();
  }
}
