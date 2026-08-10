import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'media_service.dart';

class StoryService {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  Future<void> postStory(File mediaFile, String mediaType, {String? circleId}) async {
    final uid = _auth.currentUser!.uid;
    final path = 'stories/$uid/${DateTime.now().millisecondsSinceEpoch}';
    await MediaService.uploadFile(mediaFile, 'media', path);

    final now = DateTime.now();
    await _db.collection('stories').add({
      'userId': uid,
      'mediaPath': path,
      'mediaType': mediaType,
      'visibleToCircleId': circleId,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> feedStories() {
    final now = Timestamp.now();
    return _db
        .collection('stories')
        .where('expiresAt', isGreaterThan: now)
        .orderBy('expiresAt')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}
