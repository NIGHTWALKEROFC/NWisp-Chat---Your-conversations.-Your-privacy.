import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../models/local_message.dart';
import 'local_message_store.dart';

/// Feature: "Note to self" — a private notepad that looks and lives like a
/// chat, with yourself as the only person in it.
///
/// It is stored in the SAME encrypted on-device database as every other chat
/// (see LocalMessageStore) under one fixed conversation id, and that is ALL
/// it is: nothing is ever sent to Supabase, Firebase or any other phone, no
/// push is involved, and there's no Firestore conversation document for it.
/// Because it's ordinary local chat data:
///   * it's encrypted at rest like everything else;
///   * it disappears with the rest of the local data when a different
///     account signs in, or when the app's data is wiped (panic PIN, etc.);
///   * it appears in the chat list and in search, both of which special-case
///     [conversationId] so they open the notepad instead of a chat screen.
class NoteToSelfService {
  NoteToSelfService._();

  /// The one conversation id every note lives under. It can't collide with a
  /// real 1:1 chat id (those are built from two user ids) or a group id
  /// (those always start with "group_").
  static const conversationId = 'notes_self';

  static bool isNotes(String id) => id == conversationId;

  static const _uuid = Uuid();

  /// All notes, oldest first, kept up to date.
  static Stream<List<LocalMessage>> watch() => LocalMessageStore.watchConversation(conversationId);

  static Future<void> add(String text) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final trimmed = text.trim();
    if (uid == null || trimmed.isEmpty) return;
    await LocalMessageStore.insert(
      id: _uuid.v4(),
      conversationId: conversationId,
      // "The other person" is you, which is what makes it a note to self.
      peerUid: uid,
      senderUid: uid,
      isMine: true,
      text: trimmed,
      messageType: 'text',
      // Already "read" by definition — a note to yourself is never unread,
      // so it can never add to the unread badge.
      status: 'read',
      createdAt: DateTime.now(),
    );
  }

  static Future<void> edit(String id, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await LocalMessageStore.editMessage(id, trimmed);
  }

  static Future<void> delete(List<String> ids) => LocalMessageStore.deleteMessages(ids);

  static Future<void> clearAll() => LocalMessageStore.clearConversation(conversationId);
}
