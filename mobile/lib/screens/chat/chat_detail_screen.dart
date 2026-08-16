import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/local_message.dart';
import '../../services/auth_service.dart';
import '../../services/conversation_service.dart';
import '../../services/local_message_store.dart';
import '../../services/message_relay_service.dart';
import '../../services/pin_service.dart';
import '../../services/presence_service.dart';
import 'chat_settings_screen.dart';

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
  final _conversationService = ConversationService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  LocalMessage? _replyingTo;
  Set<String> _pinnedIds = {};
  bool _readReceiptsEnabled = true;

  int? _profileTtlHours;
  int? _chatTtlOverride;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _convoSub;

  int get _effectiveTtlHours => _chatTtlOverride ?? _profileTtlHours ?? 24;

  @override
  void initState() {
    super.initState();
    _conversationService.ensureConversation(otherUid: widget.peerUid);
    AuthService().currentUserProfile().then((doc) {
      if (!mounted) return;
      setState(() {
        _profileTtlHours = (doc.data()?['messageTtlHours'] as num?)?.toInt();
        _readReceiptsEnabled = (doc.data()?['readReceiptsEnabled'] as bool?) ?? true;
      });
    });
    _convoSub = _conversationService.conversationStream(widget.conversationId).listen((doc) {
      if (!mounted) return;
      setState(() => _chatTtlOverride = (doc.data()?['chatTtlHours'] as num?)?.toInt());
    });
    PinService.pinnedFor(widget.conversationId).then((ids) {
      if (mounted) setState(() => _pinnedIds = ids.toSet());
    });
  }

  void _onTextChanged(String value) {
    _conversationService.setTyping(widget.conversationId, value.isNotEmpty);
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_myUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're not signed in. Please sign in again.")),
      );
      return;
    }
    _textController.clear();
    final replyId = _replyingTo?.id;
    setState(() => _replyingTo = null);
    try {
      await MessageRelayService.sendMessage(
        conversationId: widget.conversationId,
        recipientUid: widget.peerUid,
        text: text,
        replyToId: replyId,
        ttlHours: _effectiveTtlHours,
      );
    } on NotSignedInException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on BlockedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message could not be sent')));
    }
    await _conversationService.setTyping(widget.conversationId, false);
  }

  void _showReactionPicker(LocalMessage message) {
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
                  final uid = _myUid;
                  if (uid == null) return;
                  LocalMessageStore.setReaction(message.id, uid, emoji);
                  MessageRelayService.sendReaction(
                    conversationId: widget.conversationId,
                    toUid: widget.peerUid,
                    messageId: message.id,
                    emoji: emoji,
                  );
                  Navigator.pop(sheetContext);
                },
                icon: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            IconButton(
              iconSize: 28,
              onPressed: () {
                final uid = _myUid;
                if (uid == null) return;
                LocalMessageStore.setReaction(message.id, uid, null);
                MessageRelayService.sendReaction(
                  conversationId: widget.conversationId,
                  toUid: widget.peerUid,
                  messageId: message.id,
                  emoji: null,
                );
                Navigator.pop(sheetContext);
              },
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessageActions(LocalMessage message) {
    final isPinned = _pinnedIds.contains(message.id);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('React'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showReactionPicker(message);
              },
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() => _replyingTo = message);
              },
            ),
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(isPinned ? 'Unpin' : 'Pin'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await PinService.togglePin(widget.conversationId, message.id);
                final ids = await PinService.pinnedFor(widget.conversationId);
                if (mounted) setState(() => _pinnedIds = ids.toSet());
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy text'),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: message.text));
              },
            ),
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await MessageRelayService.deleteForMe(message.id);
              },
            ),
            if (message.isMine)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                title: Text('Delete for everyone', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await MessageRelayService.deleteForEveryone(
                    conversationId: widget.conversationId,
                    toUid: widget.peerUid,
                    messageId: message.id,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _conversationService.setTyping(widget.conversationId, false);
    _convoSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: PresenceService.watchUser(widget.peerUid),
              builder: (context, snapshot) {
                final online = (snapshot.data?.data()?['online'] as bool?) ?? false;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        widget.peerUsername.isNotEmpty ? widget.peerUsername[0].toUpperCase() : '?',
                        style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                      ),
                    ),
                    if (online)
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.shade400,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: PresenceService.watchUser(widget.peerUid),
                builder: (context, snapshot) {
                  final data = snapshot.data?.data();
                  final online = (data?['online'] as bool?) ?? false;
                  final lastSeenVisible = (data?['lastSeenVisible'] as bool?) ?? true;
                  final lastSeen = data?['lastSeen'] as Timestamp?;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.peerUsername, overflow: TextOverflow.ellipsis),
                      if (lastSeenVisible)
                        Text(
                          online ? 'Online' : _lastSeenLabel(lastSeen?.toDate()),
                          style: TextStyle(fontSize: 12, color: online ? scheme.primary : scheme.onSurfaceVariant),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Chat settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatSettingsScreen(
                  conversationId: widget.conversationId,
                  peerUid: widget.peerUid,
                  peerUsername: widget.peerUsername,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(color: scheme.onSurface.withValues(alpha: 0.05))),
          ),
          Column(
            children: [
              Container(
                width: double.infinity,
                color: scheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.timer_outlined, size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      'New messages disappear after ${_ttlLabel(_effectiveTtlHours)}'
                      '${_chatTtlOverride != null ? ' (set for this chat)' : ''}',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<LocalMessage>>(
                  stream: LocalMessageStore.watchConversation(widget.conversationId),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    final messages = snapshot.data!;
                    if (messages.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mark_chat_read_outlined, size: 44, color: scheme.primary.withValues(alpha: 0.4)),
                            const SizedBox(height: 10),
                            Text('Say hello 👋', style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      );
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                      }
                      final unread = messages.where((m) => !m.isMine && m.status != 'read');
                      if (unread.isNotEmpty) {
                        LocalMessageStore.markConversationRead(widget.conversationId);
                        if (_readReceiptsEnabled) {
                          for (final m in unread) {
                            MessageRelayService.sendReadReceipt(
                              conversationId: widget.conversationId,
                              toUid: widget.peerUid,
                              ref: m.id,
                            );
                          }
                        }
                      }
                    });
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final msg = messages[i];
                        LocalMessage? replySource;
                        if (msg.replyToId != null) {
                          for (final m in messages) {
                            if (m.id == msg.replyToId) {
                              replySource = m;
                              break;
                            }
                          }
                        }
                        return _MessageBubble(
                          isMine: msg.isMine,
                          text: msg.text,
                          replyPreview: replySource?.text,
                          reactions: msg.reactions.values.toList(),
                          status: msg.isMine ? msg.status : null,
                          pinned: _pinnedIds.contains(msg.id),
                          onLongPress: () => _showMessageActions(msg),
                          onSwipeReply: () => setState(() => _replyingTo = msg),
                        );
                      },
                    );
                  },
                ),
              ),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _conversationService.typingStream(widget.conversationId),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _TypingPulse(color: scheme.primary),
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
                      Container(width: 3, height: 28, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Replying to: ${_replyingTo!.text}',
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
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          child: TextField(
                            controller: _textController,
                            onChanged: _onTextChanged,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              border: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                          ),
                        ),
                        child: IconButton(
                          onPressed: _send,
                          icon: Icon(Icons.arrow_upward_rounded, color: scheme.onPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _ttlLabel(int hours) {
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  String _lastSeenLabel(DateTime? lastSeen) {
    if (lastSeen == null) return 'Offline';
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inHours < 1) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Last seen ${diff.inHours}h ago';
    return 'Last seen ${diff.inDays}d ago';
  }
}

class _MessageBubble extends StatelessWidget {
  final bool isMine;
  final String text;
  final String? replyPreview;
  final List<String> reactions;
  final String? status;
  final bool pinned;
  final VoidCallback onLongPress;
  final VoidCallback onSwipeReply;

  const _MessageBubble({
    required this.isMine,
    required this.text,
    required this.replyPreview,
    required this.reactions,
    required this.status,
    required this.pinned,
    required this.onLongPress,
    required this.onSwipeReply,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isMine ? 18 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 18),
    );

    return Dismissible(
      key: UniqueKey(),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        onSwipeReply();
        return false;
      },
      background: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(Icons.reply_rounded, color: scheme.primary),
        ),
      ),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 4),
          child: Align(
            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (pinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Icon(Icons.push_pin, size: 12, color: scheme.onSurfaceVariant),
                  ),
                Container(
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                  decoration: BoxDecoration(
                    gradient: isMine
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [scheme.primary, scheme.primary.withValues(alpha: 0.82)],
                          )
                        : null,
                    color: isMine ? null : scheme.surfaceContainerHigh,
                    borderRadius: radius,
                    boxShadow: isMine
                        ? [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (replyPreview != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: (isMine ? Colors.white : scheme.primary).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            replyPreview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isMine ? Colors.white70 : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      Text(
                        text,
                        style: TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
                      ),
                      if (isMine && status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Icon(
                              status == 'read'
                                  ? Icons.done_all
                                  : status == 'delivered'
                                      ? Icons.done_all
                                      : Icons.done,
                              size: 14,
                              color: status == 'read' ? Colors.lightBlueAccent : scheme.onPrimary.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (reactions.isNotEmpty)
                  Transform.translate(
                    offset: const Offset(0, -8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                      ),
                      child: Text(reactions.join(' '), style: const TextStyle(fontSize: 13)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingPulse extends StatefulWidget {
  final Color color;
  const _TypingPulse({required this.color});

  @override
  State<_TypingPulse> createState() => _TypingPulseState();
}

class _TypingPulseState extends State<_TypingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = (_controller.value + (i * 0.2)) % 1.0;
              final scale = 0.6 + 0.4 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color color;
  const _DotGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 22.0;
    for (double y = 0; y < size.height; y += spacing) {
      for (double x = 0; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}
