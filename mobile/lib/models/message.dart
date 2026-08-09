class ChatMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String plaintext; // decrypted locally, never stored server-side
  final String messageType;
  final String? mediaUrl;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.plaintext,
    required this.messageType,
    this.mediaUrl,
    required this.createdAt,
  });
}
