import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/conversation_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/moderation_service.dart';

const _chatTtlOptions = [1, 6, 24, 72, 168]; // hours: 1h, 6h, 1d, 3d, 7d

class ChatSettingsScreen extends StatefulWidget {
  final String conversationId;
  final String peerUid;
  final String peerUsername;

  const ChatSettingsScreen({
    super.key,
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  final _conversationService = ConversationService();
  final _moderationService = ModerationService();
  bool _clearing = false;

  String _ttlLabel(int? hours) {
    if (hours == null) return 'Use app default';
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  void _openTtlPicker(int? current) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Auto-delete for this chat', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            RadioListTile<int?>(
              value: null,
              groupValue: current,
              title: const Text('Use app default'),
              subtitle: const Text('Follows your Settings > Auto-delete messages value'),
              onChanged: (value) async {
                await _conversationService.setChatTtlHours(widget.conversationId, null);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
            for (final hours in _chatTtlOptions)
              RadioListTile<int?>(
                value: hours,
                groupValue: current,
                title: Text(_ttlLabel(hours)),
                onChanged: (value) async {
                  await _conversationService.setChatTtlHours(widget.conversationId, hours);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear this chat?'),
        content: Text(
          'This deletes every message in this chat for both you and @${widget.peerUsername}. '
          'This can\'t be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear chat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearing = true);
    try {
      await MessageRelayService.clearForBoth(conversationId: widget.conversationId, toUid: widget.peerUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat cleared')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not clear chat')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _confirmBlock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Block ${widget.peerUsername}?'),
        content: const Text('They will no longer be able to message you.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _moderationService.blockUser(widget.peerUid);
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.pop(context);
  }

  Future<void> _report() async {
    await _moderationService.reportUser(widget.peerUid, 'Reported from chat settings');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat settings')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _conversationService.conversationStream(widget.conversationId),
        builder: (context, snapshot) {
          final data = snapshot.data?.data() ?? {};
          final muted = _conversationService.isMutedByMe(data);
          final chatTtl = (data['chatTtlHours'] as num?)?.toInt();

          return ListView(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(widget.peerUsername.isNotEmpty ? widget.peerUsername[0].toUpperCase() : '?'),
                ),
                title: Text(widget.peerUsername, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Divider(height: 24),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.notifications_off_outlined),
                title: const Text('Mute notifications'),
                subtitle: const Text('Turn off alerts for this chat only'),
                value: muted,
                onChanged: (v) => _conversationService.setMuted(widget.conversationId, v),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Auto-delete messages'),
                subtitle: Text(_ttlLabel(chatTtl)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openTtlPicker(chatTtl),
              ),
              ListTile(
                leading: Icon(Icons.delete_sweep_outlined, color: scheme.error),
                title: Text('Clear chat', style: TextStyle(color: scheme.error)),
                subtitle: const Text('Deletes all messages in this chat, on both devices'),
                trailing: _clearing
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: _clearing ? null : _confirmClearChat,
              ),
              const Divider(height: 24),
              ListTile(
                leading: Icon(Icons.block, color: scheme.error),
                title: Text('Block ${widget.peerUsername}', style: TextStyle(color: scheme.error)),
                onTap: _confirmBlock,
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text('Report ${widget.peerUsername}'),
                onTap: _report,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
