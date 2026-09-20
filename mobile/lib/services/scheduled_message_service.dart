import 'package:flutter/material.dart';

import '../../services/scheduled_message_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../widgets/schedule_send_sheet.dart';

/// Feature: "Send later" — the list of messages waiting to be sent.
///
/// Opened from the "N scheduled" bar inside a chat (pass [conversationId] to
/// show only that chat's) or from the chat list's 3-dot menu (leave it null to
/// show everything, with each message's recipient named).
class ScheduledMessagesScreen extends StatefulWidget {
  final String? conversationId;
  final String? title;

  const ScheduledMessagesScreen({super.key, this.conversationId, this.title});

  @override
  State<ScheduledMessagesScreen> createState() => _ScheduledMessagesScreenState();
}

class _ScheduledMessagesScreenState extends State<ScheduledMessagesScreen> {
  @override
  void initState() {
    super.initState();
    // The waiting messages are private text — keep them out of screenshots
    // and the recent-apps preview.
    ScreenshotGuardService.acquire();
  }

  @override
  void dispose() {
    ScreenshotGuardService.release();
    super.dispose();
  }

  Future<void> _confirmCancel(ScheduledMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this scheduled message?'),
        content: const Text("It won't be sent."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await ScheduledMessageService.instance.cancel(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showRecipient = widget.conversationId == null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title == null ? 'Scheduled messages' : 'Scheduled for ${widget.title}')),
      body: ValueListenableBuilder<List<ScheduledMessage>>(
        valueListenable: ScheduledMessageService.instance.items,
        builder: (context, all, _) {
          final list = widget.conversationId == null
              ? all
              : all.where((m) => m.conversationId == widget.conversationId).toList();
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule, size: 56, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text('Nothing scheduled', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Type a message in a chat, then press and hold the send button to schedule it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final m = list[i];
              return ListTile(
                isThreeLine: true,
                leading: CircleAvatar(
                  backgroundColor: m.isFailed ? scheme.errorContainer : scheme.primaryContainer,
                  child: Icon(
                    m.isFailed ? Icons.warning_amber_rounded : Icons.schedule,
                    color: m.isFailed ? scheme.onErrorContainer : scheme.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  showRecipient ? 'To ${m.peerUsername.isEmpty ? 'contact' : m.peerUsername}' : m.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showRecipient) Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(m.isFailed ? Icons.error_outline : Icons.access_time, size: 14, color: m.isFailed ? scheme.error : scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            m.isFailed ? 'Was due ${formatScheduledTime(m.sendAt)}' : formatScheduledTime(m.sendAt),
                            style: TextStyle(fontSize: 12.5, color: m.isFailed ? scheme.error : scheme.onSurfaceVariant),
                          ),
                        ),
                        if (m.silent) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.notifications_off_outlined, size: 14, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Text('Silent', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                        ],
                      ],
                    ),
                    if (m.isFailed && m.failReason != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(m.failReason!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
                      ),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'now') {
                      ScheduledMessageService.instance.sendNow(m.id);
                    } else if (value == 'delete') {
                      _confirmCancel(m);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'now', child: Text(m.isFailed ? 'Send now' : 'Send now instead')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
