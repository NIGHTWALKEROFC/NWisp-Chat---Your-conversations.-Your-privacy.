import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/moderation_service.dart';

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});
  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final _moderationService = ModerationService();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _moderationService.myProfileStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final blocked = List<String>.from(snapshot.data!.data()?['blockedUsers'] ?? []);
          if (blocked.isEmpty) {
            return Center(
              child: Text('No blocked users', style: TextStyle(color: scheme.onSurfaceVariant)),
            );
          }
          return ListView.builder(
            itemCount: blocked.length,
            itemBuilder: (context, i) {
              final uid = blocked[i];
              return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
                builder: (context, userSnapshot) {
                  final username = (userSnapshot.data?.data()?['username'] as String?) ?? uid;
                  return ListTile(
                    leading: const Icon(Icons.block),
                    title: Text(username),
                    trailing: TextButton(
                      onPressed: () => _moderationService.unblockUser(uid),
                      child: const Text('Unblock'),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
