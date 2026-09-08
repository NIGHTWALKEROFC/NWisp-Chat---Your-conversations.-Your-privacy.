import 'package:flutter/material.dart';
import '../../services/chat_freeze_service.dart';
import '../../services/contact_service.dart';

/// Feature: mutual timed block ("Pause this chat"). The one place either
/// person can see and end a pause early — the paused conversation itself
/// is completely hidden from the normal chat list for as long as it's
/// active, so this is deliberately reachable from Settings, not from
/// anywhere near the chat itself.
class PausedChatsScreen extends StatelessWidget {
  const PausedChatsScreen({super.key});

  Future<void> _endEarly(BuildContext context, String otherUid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End the pause?'),
        content: const Text('This chat will become visible and messageable again for both of you right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('End pause')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChatFreezeService.instance.endEarly(otherUid);
  }

  String _timeRemaining(DateTime expiresAt) {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.inDays >= 1) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} left';
    if (diff.inHours >= 1) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} left';
    if (diff.inMinutes >= 1) return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} left';
    return 'Reopening any moment now';
  }

  @override
  Widget build(BuildContext context) {
    final contactService = ContactService();
    return Scaffold(
      appBar: AppBar(title: const Text('Paused chats')),
      body: StreamBuilder<List<FrozenChatInfo>>(
        stream: ChatFreezeService.instance.watchMyActiveFreezes(),
        builder: (context, snapshot) {
          final freezes = snapshot.data ?? [];
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (freezes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pause_circle_outline, size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 16),
                    const Text('No paused chats right now', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: freezes.length,
            itemBuilder: (context, i) {
              final f = freezes[i];
              return FutureBuilder<Map<String, dynamic>?>(
                future: contactService.userByUid(f.otherUid),
                builder: (context, userSnap) {
                  final username = (userSnap.data?['username'] as String?) ?? '…';
                  return ListTile(
                    leading: CircleAvatar(child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?')),
                    title: Text(username),
                    subtitle: Text(_timeRemaining(f.expiresAt)),
                    trailing: TextButton(
                      onPressed: () => _endEarly(context, f.otherUid),
                      child: const Text('End early'),
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
