import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/local_message_store.dart';
import 'chat/chat_detail_screen.dart';
import 'groups/group_chat_screen.dart';

/// Feature: starred/saved messages. A personal bookmark list across every
/// chat and group — entirely device-local (see LocalMessage.starred's doc
/// comment: never synced, never visible to anyone else, unlike pinning).
/// Tapping a result opens that exact conversation; there's no in-place
/// preview here since the whole point is a quick way back to something,
/// not a second place to read a message start-to-finish.
class StarredMessagesScreen extends StatefulWidget {
  const StarredMessagesScreen({super.key});

  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  final Map<String, String> _usernameCache = {};
  final Map<String, String> _groupNameCache = {};

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  Future<String> _groupNameFor(String groupId) async {
    if (_groupNameCache.containsKey(groupId)) return _groupNameCache[groupId]!;
    final doc = await FirebaseFirestore.instance.collection('groups').doc(groupId).get();
    final name = (doc.data()?['name'] as String?) ?? 'Group';
    _groupNameCache[groupId] = name;
    return name;
  }

  Future<String> _labelFor(LocalMessage m) {
    return m.conversationId.startsWith('group_') ? _groupNameFor(m.conversationId) : _usernameFor(m.peerUid);
  }

  Future<void> _open(LocalMessage m) async {
    if (m.conversationId.startsWith('group_')) {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: StreamBuilder<List<LocalMessage>>(
        stream: LocalMessageStore.watchStarred(),
        builder: (context, snapshot) {
          final messages = snapshot.data ?? [];
          if (messages.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_border, size: 48, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(
                      'No starred messages yet — long-press any message and tap Star to save it here',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: messages.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final m = messages[i];
              return ListTile(
                leading: const Icon(Icons.star, color: Colors.amber),
                title: FutureBuilder<String>(
                  future: _labelFor(m),
                  builder: (context, snap) => Text(snap.data ?? '…', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                subtitle: Text(
                  m.messageType == 'text' ? m.text : (m.messageType == 'image' ? 'Photo' : m.messageType == 'video' ? 'Video' : 'Voice message'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.star, color: Colors.amber),
                  tooltip: 'Unstar',
                  onPressed: () => LocalMessageStore.toggleStar(m.id),
                ),
                onTap: () => _open(m),
              );
            },
          );
        },
      ),
    );
  }
}
