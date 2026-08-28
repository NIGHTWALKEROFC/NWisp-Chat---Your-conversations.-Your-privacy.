class LocalMessage {
  final String id;
  final String conversationId;
  final String peerUid;
  final String senderUid;
  final bool isMine;
  final String text;
  final String messageType;
  final String? mediaPath;
  final String? replyToId;
  final Map<String, String> reactions;
  final String status; // sent | delivered | read
  final DateTime createdAt;
  final DateTime? expiresAt;

  /// Set the first time this message is edited (see
  /// LocalMessageStore.editMessage / MessageRelayService.editMessage) —
  /// null means "never edited". Bubbles show a small "(edited)" label
  /// when this is non-null.
  final DateTime? editedAt;

  const LocalMessage({
    required this.id,
    required this.conversationId,
    required this.peerUid,
    required this.senderUid,
    required this.isMine,
    required this.text,
    required this.messageType,
    this.mediaPath,
    this.replyToId,
    this.reactions = const {},
    this.status = 'sent',
    required this.createdAt,
    this.expiresAt,
    this.editedAt,
  });
}

/// One queued group-message copy waiting to be retried to a specific
/// member once they publish a Signal key bundle (see
/// ContactNotUpgradedException / LocalMessageStore.queuePendingGroupResend
/// / GroupMessageRelayService.retryPendingResends). [payload] is the
/// plaintext that still needs to be Signal-encrypted for [uid] — for a
/// text message that's the message text itself; for media it's the same
/// small JSON metadata blob (fileKey/nonce/mime/etc.) the original send
/// used, since the actual file bytes are already uploaded once and shared
/// by every member.
class PendingGroupResend {
  final String id;
  final String groupId;
  final String clientId;
  final String uid;
  final String payload;
  final String messageType;
  final String? mediaPath;
  final String? replyToId;
  final int ttlHours;
  final DateTime createdAt;

  const PendingGroupResend({
    required this.id,
    required this.groupId,
    required this.clientId,
    required this.uid,
    required this.payload,
    required this.messageType,
    this.mediaPath,
    this.replyToId,
    required this.ttlHours,
    required this.createdAt,
  });
}

class ConversationSummary {
  final String conversationId;
  final String peerUid;
  final String lastText;
  final DateTime lastAt;
  final int unreadCount;

  /// Phase 7 (group chats): true when `conversationId` is a group id (see
  /// GroupService.newGroupId). For a group row, [peerUid] is whoever sent
  /// the LAST message (see LocalMessageStore — group rows always set
  /// peer_uid == sender_uid), not "the other person" the way it means for
  /// a 1:1 row.
  final bool isGroup;
  final String? groupName;
  final String? groupAvatarUrl;

  const ConversationSummary({
    required this.conversationId,
    required this.peerUid,
    required this.lastText,
    required this.lastAt,
    required this.unreadCount,
    this.isGroup = false,
    this.groupName,
    this.groupAvatarUrl,
  });
}
