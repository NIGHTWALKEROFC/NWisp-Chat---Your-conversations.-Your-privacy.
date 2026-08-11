import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../chat/chat_detail_screen.dart';
import 'find_users_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with SingleTickerProviderStateMixin {
  final _contactService = ContactService();
  final _conversationService = ConversationService();
  final _authService = AuthService();
  late final TabController _tabController = TabController(length: 2, vsync: this);

  Future<void> _openChat(String uid, String username) async {
    final myProfile = await _authService.currentUserProfile();
    final myUsername = (myProfile.data()?['username'] as String?) ?? '';
    final conversationId = await _conversationService.getOrCreateConversation(
      otherUid: uid,
      myUsername: myUsername,
      otherUsername: username,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(conversationId: conversationId, peerUid: uid, peerUsername: username),
      ),
    );
  }

  Widget _errorState(BuildContext context, Object? error) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text('Could not load this', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('$error', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: 'Contacts'), Tab(text: 'Requests')],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: 'Find people',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FindUsersScreen()),
            ),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          StreamBuilder(
            stream: _contactService.contactsStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return _errorState(context, snapshot.error);
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline, size: 64, color: scheme.primary.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        const Text('No contacts yet'),
                        const SizedBox(height: 4),
                        Text('Tap the add-person icon to find people by username.',
                            textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final data = docs[i].data();
                  final username = (data['username'] as String?) ?? '';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                    ),
                    title: Text(username),
                    trailing: const Icon(Icons.chat_bubble_outline),
                    onTap: () => _openChat(docs[i].id, username),
                  );
                },
              );
            },
          ),
          StreamBuilder(
            stream: _contactService.incomingRequestsStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return _errorState(context, snapshot.error);
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return Center(
                  child: Text('No pending requests', style: TextStyle(color: scheme.onSurfaceVariant)),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final data = docs[i].data();
                  final fromUid = data['fromUid'] as String;
                  final fromUsername = (data['fromUsername'] as String?) ?? '';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(fromUsername.isNotEmpty ? fromUsername[0].toUpperCase() : '?'),
                    ),
                    title: Text(fromUsername),
                    subtitle: const Text('wants to add you'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.check_circle, color: scheme.primary),
                          onPressed: () => _contactService.acceptRequest(docs[i].id, fromUid, fromUsername),
                        ),
                        IconButton(
                          icon: Icon(Icons.cancel_outlined, color: scheme.error),
                          onPressed: () => _contactService.declineRequest(docs[i].id),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
