import 'package:flutter/material.dart';
import '../../services/broadcast_list_service.dart';
import 'broadcast_list_screen.dart';
import 'create_broadcast_list_screen.dart';

/// Feature: broadcast lists home — "your saved lists", each opening into
/// BroadcastListScreen to compose/send. Entry point is chat_list_screen.dart's
/// existing "+" menu ("Broadcast lists").
class BroadcastListsScreen extends StatelessWidget {
  const BroadcastListsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast lists')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBroadcastListScreen())),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<BroadcastList>>(
        stream: BroadcastListService.watchLists(),
        builder: (context, snapshot) {
          final lists = snapshot.data ?? [];
          if (lists.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.campaign_outlined, size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    const Text('No broadcast lists yet', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      'Send one message to several people at once, each as their own private '
                      "chat with you — not a group, and they won't see each other.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBroadcastListScreen())),
                      icon: const Icon(Icons.add),
                      label: const Text('New broadcast list'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: lists.length,
            itemBuilder: (context, i) {
              final list = lists[i];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.campaign_outlined)),
                title: Text(list.name),
                subtitle: Text('${list.memberUids.length} recipient${list.memberUids.length == 1 ? '' : 's'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BroadcastListScreen(listId: list.id))),
              );
            },
          );
        },
      ),
    );
  }
}
