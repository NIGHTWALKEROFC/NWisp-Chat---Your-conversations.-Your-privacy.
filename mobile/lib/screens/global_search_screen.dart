import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/private_keyboard_service.dart';
import '../services/local_message_store.dart';
import 'chat/chat_detail_screen.dart';
import 'groups/group_chat_screen.dart';

/// Feature: global search across all chats. Two sections:
///   - "Chats & Groups": conversations whose name (group name, or the
///     other person's username for a 1:1) matches — lets someone jump
///     straight to a conversation the way tapping it in the chat list
///     would, without a message match being required at all.
///   - "Messages": actual message text matches across every
///     conversation, via LocalMessageStore.searchAll — same in-memory,
///     already-decrypted, no-server-index approach as the existing
///     per-chat search (see chat_search_screen.dart).
/// Tapping a message result opens that exact chat and scrolls straight
/// to it, the same way returning from the per-chat search screen does.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final _controller = TextEditingController();
  final Map<String, String> _usernameCache = {};
  List<ConversationSummary> _allSummaries = [];
  List<ConversationSummary> _chatResults = [];
  List<LocalMessage> _messageResults = [];
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    LocalMessageStore.watchSummaries().first.then((s) {
      if (mounted) setState(() => _allSummaries = s);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  Future<void> _runSearch(String query) async {
    final needle = query.trim();
    if (needle.isEmpty) {
      setState(() {
        _chatResults = [];
        _messageResults = [];
        _searched = false;
      });
      return;
    }
    final lower = needle.toLowerCase();
    final chatMatches = <ConversationSummary>[];
    for (final s in _allSummaries) {
      final label = s.isGroup ? (s.groupName ?? 'Group') : await _usernameFor(s.peerUid);
      if (label.toLowerCase().contains(lower)) chatMatches.add(s);
    }
    final messageMatches = await LocalMessageStore.searchAll(needle);
    if (!mounted) return;
    setState(() {
      _chatResults = chatMatches;
      _messageResults = messageMatches;
      _searched = true;
    });
  }

  void _openChat(ConversationSummary s) {
    if (s.isGroup) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: s.conversationId)));
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailScreen(conversationId: s.conversationId, peerUid: s.peerUid, peerUsername: _usernameCache[s.peerUid] ?? '…'),
        ),
      );
    }
  }

  Future<void> _openMessage(LocalMessage m) async {
    final isGroup = _allSummaries.any((s) => s.conversationId == m.conversationId && s.isGroup) || m.conversationId.startsWith('group_');
    if (isGroup) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: m.conversationId)));
    } else {
      final username = await _usernameFor(m.peerUid);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatDetailScreen(conversationId: m.conversationId, peerUid: m.peerUid, peerUsername: username)),
      );
    }
  }

  String _snippet(String text, String query) {
    final lower = text.toLowerCase();
    final idx = lower.indexOf(query.toLowerCase());
    if (idx < 0) return text;
    const window = 40;
    final start = (idx - window).clamp(0, text.length);
    final end = (idx + query.length + window).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          // Feature: private keyboard mode (off by default).
          enableSuggestions: !PrivateKeyboardService.enabled.value,
          autocorrect: !PrivateKeyboardService.enabled.value,
          enableIMEPersonalizedLearning: !PrivateKeyboardService.enabled.value,
          controller: _controller,
          autofocus: true,
          onChanged: _runSearch,
          decoration: const InputDecoration(hintText: 'Search chats, groups, and messages', border: InputBorder.none),
          style: TextStyle(color: scheme.onSurface),
        ),
      ),
      body: !_searched
          ? Center(child: Text('Type to search everything', style: TextStyle(color: scheme.onSurfaceVariant)))
          : (_chatResults.isEmpty && _messageResults.isEmpty)
              ? Center(child: Text('No matches', style: TextStyle(color: scheme.onSurfaceVariant)))
              : ListView(
                  children: [
                    if (_chatResults.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Chats & Groups', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                      ),
                      ..._chatResults.map((s) => ListTile(
                            leading: CircleAvatar(child: Icon(s.isGroup ? Icons.groups_rounded : Icons.person)),
                            title: FutureBuilder<String>(
                              future: s.isGroup ? Future.value(s.groupName ?? 'Group') : _usernameFor(s.peerUid),
                              builder: (context, snap) => Text(snap.data ?? '…'),
                            ),
                            onTap: () => _openChat(s),
                          )),
                      const Divider(),
                    ],
                    if (_messageResults.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Messages', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                      ),
                      ..._messageResults.map((m) => ListTile(
                            leading: Icon(m.isMine ? Icons.arrow_upward : Icons.arrow_downward, size: 18),
                            title: FutureBuilder<String>(
                              future: m.conversationId.startsWith('group_')
                                  ? Future.value(_allSummaries.firstWhere((s) => s.conversationId == m.conversationId, orElse: () => ConversationSummary(conversationId: m.conversationId, peerUid: m.peerUid, lastText: '', lastAt: m.createdAt, unreadCount: 0, isGroup: true, groupName: 'Group')).groupName ?? 'Group')
                                  : _usernameFor(m.peerUid),
                              builder: (context, snap) => Text(snap.data ?? '…', style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                            subtitle: Text(_snippet(m.text, _controller.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => _openMessage(m),
                          )),
                    ],
                  ],
                ),
    );
  }
}
