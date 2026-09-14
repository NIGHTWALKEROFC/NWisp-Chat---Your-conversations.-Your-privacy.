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
  final String status; // sending | sent | delivered | read | failed
  final DateTime createdAt;
  final DateTime? expiresAt;

  /// Set the first time this message is edited (see
  /// LocalMessageStore.editMessage / MessageRelayService.editMessage) —
  /// null means "never edited". Bubbles show a small "(edited)" label
  /// when this is non-null.
  final DateTime? editedAt;

  /// Group security setting: media auto-download restrictions. True when
  /// this is an image/video whose bytes were deliberately NOT fetched yet
  /// (the group has auto-download turned off) — mediaPath is null but,
  /// unlike a genuine failed/broken download, a manual download is still
  /// possible (see MessageRelayService.downloadPendingMedia). The UI
  /// should show a tap-to-download state instead of the usual "unavailable"
  /// placeholder when this is true.
  final bool hasPendingMedia;

  /// Feature: view-once media. True for a photo/video sent as
  /// "view once" — the RECEIVER can open it exactly one time; after the
  /// viewer is closed, [LocalMessageStore.consumeViewOnce] deletes the
  /// file from disk and sets mediaPath back to null, and this flag stays
  /// true forever as a record that the message WAS view-once (see
  /// [viewOnceConsumed] for whether it's already been opened). The
  /// SENDER's own copy is never auto-deleted this way — only the
  /// recipient's — matching Signal/WhatsApp's own view-once behavior.
  final bool isViewOnce;

  /// Only meaningful when [isViewOnce] is true. False until the
  /// recipient has opened it once; true afterward, at which point
  /// mediaPath is null and the bubble shows a permanent "Opened"
  /// placeholder instead of ever being viewable again.
  final bool viewOnceConsumed;

  /// Feature: starred/saved messages. Private to THIS device only — never
  /// synced to the relay or visible to anyone else, unlike pinning (which
  /// is a shared, visible-to-both conversation setting). A personal
  /// bookmark list, same idea as starring in Gmail/WhatsApp. Toggled from
  /// a message's long-press menu; browsed all together in
  /// StarredMessagesScreen.
  final bool starred;

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
    this.hasPendingMedia = false,
    this.isViewOnce = false,
    this.viewOnceConsumed = false,
    this.starred = false,
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

/// The extra bookkeeping [LocalMessageStore] keeps for a photo/video/voice
/// message while it's uploading, so a failed send can be retried without
/// re-picking the file — see LocalMessageStore.savePendingMediaSend /
/// MessageRelayService.retryMediaMessage. The caption and local media
/// file path aren't duplicated here — they're read back from the
/// `messages` row itself via LocalMessageStore.getById.
class PendingMediaSend {
  final String clientId;
  final String conversationId;
  final String? recipientUid; // null for a group send — see isGroup
  final bool isGroup;
  final String extension;
  final String mime;
  final int? durationMs;
  final int ttlHours;

  const PendingMediaSend({
    required this.clientId,
    required this.conversationId,
    this.recipientUid,
    required this.isGroup,
    required this.extension,
    required this.mime,
    this.durationMs,
    required this.ttlHours,
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
