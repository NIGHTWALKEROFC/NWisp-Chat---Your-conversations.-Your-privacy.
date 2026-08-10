import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/conversation_service.dart';
import '../../services/moderation_service.dart';
import '../../services/presence_service.dart';

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

class ChatDetailScreen extends StatefulWidget {
  final String conversationId;
  final String peerUid;
  final String peerUsername;

  const ChatDetailScreen({
    super.key,
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _chatService = ChatService();
  final _conversationService = ConversationService();
  final _moderationService = ModerationService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _myUid = FirebaseAuth.instance.currentUser!.uid;

  QueryDocumentSnapshot<Map<String, dynamic>>? _replyingTo;
  int? _ttlHours;

  @override
  void initState() {
    super.initState();
    AuthService().currentUserProfile().then((doc) {
      if (mounted) setState(() => _ttlHours = (doc.data()?['messageTtlHours'] as num?)?.toInt());
    });
  }

  void _onTextChanged(String value) {
    _chatService.setTyping(widget.conversationId, value.isNotEmpty);
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await _chatService.sendMessage(
      conversationId: widget.conversationId,
      ciphertext: text,
      replyToId: _replyingTo?.id,
      ttlHours: _ttlHours,
    );
    await _conversationService.updateLastMessage(widget.conversationId, text);
    await _chatService.setTyping(widget.conversationId, false);
    setState(() => _replyingTo = null);
  }

  void _showReactionPicker(QueryDocumentSnapshot<Map<String, dynamic>> message) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            for (final emoji in _quickReactions)
              IconButton(
                iconSize: 32,
                onPressed: () {
                  _chatService.setReaction(widget.conversationId, message.id, emoji);
                  Navigator.pop(sheetContext);
                },
                icon: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            IconButton(
              iconSize: 28,
              onPressed: () {
                _chatService.setReaction(widget.conversationId, message.id, null);
                Navigator.pop(sheetContext);
              },
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  void _showBlockReportSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.block),
              title: Text('Block ${widget.peerUsername}'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _moderationService.blockUser(widget.peerUid);
                if (mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text('Report ${widget.peerUsername}'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _moderationService.reportUser(widget.peerUid, 'Reported from chat');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Report submitted')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _chatService.setTyping(widget.conversationId, false);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: PresenceService.watchUser(widget.peerUid),
          builder: (context, snapshot) {
            final data = snapshot.data?.data();
            final online = (data?['online'] as bool?) ?? false;
            final lastSeenVisible = (data?['lastSeenVisible'] as bool?) ?? true;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.peerUsername),
                if (lastSeenVisible)
                  Text(
                    online ? 'Online' : 'Offline',
                    style: TextStyle(fontSize: 12, color: online ? scheme.primary : scheme.onSurfaceVariant),
                  ),
              ],
            );
          },
        ),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showBlockReportSheet),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _chatService.messageStream(widget.conversationId),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                    child: Text('Say hello 👋', style: TextStyle(color: scheme.onSurfaceVariant)),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                  }
                  for (final doc in docs) {
                    final readBy = List<String>.from(doc.data()['readBy'] ?? []);
                    if (doc.data()['senderId'] != _myUid && !readBy.contains(_myUid)) {
                      _chatService.markRead(widget.conversationId, doc.id);
                    }
                  }
                });
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    final data = doc.data();
                    final isMine = data['senderId'] == _myUid;
                    final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
                    final replyToId = data['replyToId'] as String?;
                    QueryDocumentSnapshot<Map<String, dynamic>>? replySource;
                    if (replyToId != null) {
                      for (final d in docs) {
                        if (d.id == replyToId) {
                          replySource = d;
                          break;
                        }
                      }
                    }
                    return GestureDetector(
                      onLongPress: () => _showReactionPicker(doc),
                      child: Align(
                        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: isMine ? scheme.primary : scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (replySource != null)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: (isMine ? Colors.white : scheme.primary).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    replySource.data()['ciphertext'] ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isMine ? Colors.white70 : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              Text(
                                data['ciphertext'] ?? '',
                                style: TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
                              ),
                              if (reactions.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Wrap(
                                    spacing: 2,
                                    children: reactions.values.map((e) => Text(e, style: const TextStyle(fontSize: 13))).toList(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _chatService.typingStream(widget.conversationId),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final peerTyping = snapshot.data!.docs.any((d) {
                if (d.id != widget.peerUid) return false;
                final isTyping = (d.data()['isTyping'] as bool?) ?? false;
                final updatedAt = d.data()['updatedAt'] as Timestamp?;
                final recent = updatedAt != null && DateTime.now().difference(updatedAt.toDate()).inSeconds < 8;
                return isTyping && recent;
              });
              if (!peerTyping) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${widget.peerUsername} is typing…',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
                ),
              );
            },
          ),
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: scheme.surfaceContainerHigh,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to: ${_replyingTo!.data()['ciphertext']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      onChanged: _onTextChanged,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: 'Message'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
