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
  });
}

class ConversationSummary {
  final String conversationId;
  final String peerUid;
  final String lastText;
  final DateTime lastAt;
  final int unreadCount;

  const ConversationSummary({
    required this.conversationId,
    required this.peerUid,
    required this.lastText,
    required this.lastAt,
    required this.unreadCount,
  });
}
