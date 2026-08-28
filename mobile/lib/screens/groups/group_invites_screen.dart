import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/group_service.dart';
import 'group_chat_screen.dart';

/// Lists group invites waiting for a response — see
/// GroupService.inviteToGroup. This is the consent step for anyone who
/// isn't already a contact of the group admin who wants to add them: they
/// show up here instead of being silently placed into the group, and
/// nothing about the group (its messages, its member list) is visible to
/// them until they explicitly accept.
class GroupInvitesScreen extends StatelessWidget {
  const GroupInvitesScreen({super.key});

  Future<void> _accept(BuildContext context, String requestId, String groupId, String groupName) async {
    try {
      await GroupService.instance.acceptGroupInvite(requestId: requestId, groupId: groupId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Joined $groupName")));
      Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't join: $e")));
    }
  }

  Future<void> _decline(BuildContext context, String requestId) async {
    await GroupService.instance.declineGroupInvite(requestId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invite declined')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Group invites')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: GroupService.instance.myGroupInviteRequestsStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mail_outline, size: 56, color: scheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 16),
                    const Text('No pending group invites'),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final data = docs[i].data();
              final groupId = data['groupId'] as String;
              final groupName = (data['groupName'] as String?) ?? 'Group';
              final groupAvatarUrl = data['groupAvatarUrl'] as String?;
              final fromUsername = (data['fromUsername'] as String?) ?? 'Someone';
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          backgroundImage: groupAvatarUrl != null ? NetworkImage(groupAvatarUrl) : null,
                          child: groupAvatarUrl == null ? const Icon(Icons.groups_rounded) : null,
                        ),
                        title: Text(groupName, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('Invited by $fromUsername'),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _decline(context, docs[i].id),
                              child: const Text('Decline'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _accept(context, docs[i].id, groupId, groupName),
                              child: const Text('Accept'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
