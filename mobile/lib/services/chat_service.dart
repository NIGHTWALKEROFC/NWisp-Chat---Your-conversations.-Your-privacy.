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
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: ttlHours))),
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
}
