import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/local_message_store.dart';
import 'chat/chat_detail_screen.dart';
import 'contacts/contacts_screen.dart';
import 'contacts/find_users_screen.dart';
import 'settings/settings_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final Map<String, String> _usernameCache = {};

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search people',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FindUsersScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<ConversationSummary>>(
        stream: LocalMessageStore.watchSummaries(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final summaries = snapshot.data!;
          if (summaries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 72, color: scheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 16),
                    Text('No conversations yet', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the button below to message a contact.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: summaries.length,
            itemBuilder: (context, i) {
              final s = summaries[i];
              return FutureBuilder<String>(
                future: _usernameFor(s.peerUid),
                builder: (context, nameSnap) {
                  final username = nameSnap.data ?? '…';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                    ),
                    title: Text(username),
                    subtitle: Text(s.lastText, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: s.unreadCount > 0
                        ? CircleAvatar(
                            radius: 11,
                            backgroundColor: scheme.primary,
                            child: Text(
                              '${s.unreadCount}',
                              style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700),
                            ),
                          )
                        : null,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatDetailScreen(
                          conversationId: s.conversationId,
                          peerUid: s.peerUid,
                          peerUsername: username,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ContactsScreen()),
        ),
        child: const Icon(Icons.chat_rounded),
      ),
    );
  }
}
