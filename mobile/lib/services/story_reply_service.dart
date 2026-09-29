import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'conversation_service.dart';
import 'message_relay_service.dart';

/// Feature: reply to a story as a private message.
///
/// A reply is just a normal, end-to-end-encrypted 1:1 message to the person
/// who posted the story — it goes through the exact same MessageRelayService
/// paths as anything typed in a chat, so blocking, paused chats, disappearing
/// -message timers and encryption all behave as usual. Nothing new is stored
/// on any server.
///
///  * Photo story  -> the photo itself is sent as an image message, with the
///    reply as its caption, so the other person sees which story you meant.
///  * Video story  -> videos are too heavy to re-send, so it goes as a text
///    message that says it's a reply to their video story (plus the story's
///    caption if it has one).
class StoryReplyService {
  StoryReplyService._();

  /// Sends [text] as a reply to [story] (a story map as used by the story
  /// viewer) posted by [ownerUid]. [imageBytes] is the already-decrypted
  /// photo the viewer has on screen (null for video stories).
  ///
  /// Returns the conversation id so the caller can open the chat.
  /// Throws whatever MessageRelayService throws (blocked, paused chat,
  /// offline...) — those exceptions already have readable messages.
  static Future<String> send({
    required String ownerUid,
    required Map<String, dynamic> story,
    required Uint8List? imageBytes,
    required String text,
  }) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) throw NotSignedInException();

    final conversations = ConversationService();
    await conversations.ensureConversation(otherUid: ownerUid);
    final conversationId = conversations.conversationIdFor(me.uid, ownerUid);
    final ttlHours = await _ttlHoursFor(conversationId, me.uid);

    final isVideo = story['mediaType'] == 'video';
    final storyCaption = ((story['caption'] as String?) ?? '').trim();

    if (!isVideo && imageBytes != null) {
      await MessageRelayService.sendMediaMessage(
        conversationId: conversationId,
        recipientUid: ownerUid,
        plainBytes: imageBytes,
        messageType: 'image',
        extension: 'jpg',
        mime: 'image/jpeg',
        caption: 'Replying to your story\n$text',
        ttlHours: ttlHours,
      );
    } else {
      final quoted = storyCaption.isEmpty ? '' : ' "$storyCaption"';
      await MessageRelayService.sendMessage(
        conversationId: conversationId,
        recipientUid: ownerUid,
        text: 'Replying to your ${isVideo ? 'video ' : ''}story$quoted\n$text',
        ttlHours: ttlHours,
      );
    }
    return conversationId;
  }

  /// Same rule the chat screen uses: this chat's own auto-delete setting if
  /// it has one, otherwise my profile-wide default, otherwise 0 (never).
  static Future<int> _ttlHoursFor(String conversationId, String myUid) async {
    final db = FirebaseFirestore.instance;
    try {
      final convo = await db.collection('conversations').doc(conversationId).get();
      final chatTtl = (convo.data()?['chatTtlHours'] as num?)?.toInt();
      if (chatTtl != null) return chatTtl;
      // messageTtlHours is a private setting — it lives under
      // users/{uid}/private/profile (see AuthService), not on the public doc.
      final profile = await db.collection('users').doc(myUid).collection('private').doc('profile').get();
      return (profile.data()?['messageTtlHours'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
