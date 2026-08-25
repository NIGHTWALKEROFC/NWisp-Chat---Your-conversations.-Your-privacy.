import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../chat/chat_detail_screen.dart';
import '../groups/create_group_screen.dart';
import 'find_users_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with SingleTickerProviderStateMixin {
  final _contactService = ContactService();
  final _conversationService = ConversationService();
  late final TabController _tabController = TabController(length: 2, vsync: this);

  String? _openingUid;

  // Long-press-to-multi-select, WhatsApp style: long-press a contact to
  // start selecting more, then tap the checkmark to create a group from
  // exactly those people.
  bool _selectionMode = false;
  final Set<String> _selectedUids = {};

  void _startSelection(String uid) {
    setState(() {
      _selectionMode = true;
      _selectedUids.add(uid);
    });
  }

  void _toggleSelection(String uid) {
    setState(() {
      if (_selectedUids.contains(uid)) {
        _selectedUids.remove(uid);
        if (_selectedUids.isEmpty) _selectionMode = false;
      } else {
        _selectedUids.add(uid);
      }
    });
  }

  void _cancelSelection() {
    setState(() {
      _selectionMode = false;
      _selectedUids.clear();
    });
  }

  Future<void> _goCreateGroup() async {
    final selected = Set<String>.from(_selectedUids);
    _cancelSelection();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CreateGroupScreen(initialSelectedUids: selected)),
    );
  }

  Future<void> _openChat(String uid, String username) async {
    if (_openingUid != null) return;
    setState(() => _openingUid = uid);
    try {
      final myUid = FirebaseAuth.instance.currentUser!.uid;
      final conversationId = _conversationService.conversationIdFor(myUid, uid);
      await _conversationService.ensureConversation(otherUid: uid);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailScreen(conversationId: conversationId, peerUid: uid, peerUsername: username),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open this chat. Check your connection and try again.")),
      );
    } finally {
      if (mounted) setState(() => _openingUid = null);
    }
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
        leading: _selectionMode
            ? IconButton(icon: const Icon(Icons.close), onPressed: _cancelSelection)
            : null,
        title: _selectionMode ? Text('${_selectedUids.length} selected') : const Text('Contacts'),
        bottom: _selectionMode
            ? null
            : TabBar(
                controller: _tabController,
                tabs: const [Tab(text: 'Contacts'), Tab(text: 'Requests')],
              ),
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.groups_rounded),
                  tooltip: 'Create group',
                  onPressed: _selectedUids.length >= 2 ? _goCreateGroup : null,
                ),
              ]
            : [
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
        physics: _selectionMode ? const NeverScrollableScrollPhysics() : null,
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
                  final uid = docs[i].id;
                  final data = docs[i].data();
                  final username = (data['username'] as String?) ?? '';
                  final isOpening = _openingUid == uid;
                  final isSelected = _selectedUids.contains(uid);
                  return ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                        ),
                        if (_selectionMode && isSelected)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              padding: const EdgeInsets.all(1.5),
                              decoration: BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
                              child: CircleAvatar(radius: 9, backgroundColor: scheme.primary, child: const Icon(Icons.check, size: 12, color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                    title: Text(username),
                    trailing: _selectionMode
                        ? null
                        : (isOpening
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.chat_bubble_outline)),
                    selected: isSelected,
                    selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                    onTap: _selectionMode ? () => _toggleSelection(uid) : () => _openChat(uid, username),
                    onLongPress: _selectionMode ? null : () => _startSelection(uid),
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
