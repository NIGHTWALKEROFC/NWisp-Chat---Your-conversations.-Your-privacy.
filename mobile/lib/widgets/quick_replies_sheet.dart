import 'package:flutter/material.dart';
import '../services/quick_reply_service.dart';

/// Feature: quick replies. Shows saved templates to pick from, with
/// inline add/edit/delete — used from both an ordinary chat's composer
/// (ChatDetailScreen) and a broadcast list's composer (BroadcastListScreen).
/// Returns the picked text, or null if the sheet was dismissed without a
/// pick (adding/editing/deleting doesn't close the sheet by itself).
Future<String?> showQuickRepliesSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _QuickRepliesSheet(),
  );
}

class _QuickRepliesSheet extends StatefulWidget {
  const _QuickRepliesSheet();
  @override
  State<_QuickRepliesSheet> createState() => _QuickRepliesSheetState();
}

class _QuickRepliesSheetState extends State<_QuickRepliesSheet> {
  Future<void> _addOrEdit({QuickReply? existing}) async {
    final controller = TextEditingController(text: existing?.text ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? 'New quick reply' : 'Edit quick reply'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(hintText: 'Message text'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(existing == null ? 'Save' : 'Update'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    if (existing == null) {
      await QuickReplyService.add(text);
    } else {
      await QuickReplyService.update(existing.id, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('Quick replies', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17))),
                    TextButton.icon(
                      onPressed: () => _addOrEdit(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: StreamBuilder<List<QuickReply>>(
                  stream: QuickReplyService.watchAll(),
                  builder: (context, snapshot) {
                    final replies = snapshot.data ?? [];
                    if (replies.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            "No quick replies saved yet — tap \"New\" to save a message you send often.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: replies.length,
                      itemBuilder: (context, i) {
                        final r = replies[i];
                        return ListTile(
                          title: Text(r.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(context, r.text),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') _addOrEdit(existing: r);
                              if (value == 'delete') QuickReplyService.delete(r.id);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
