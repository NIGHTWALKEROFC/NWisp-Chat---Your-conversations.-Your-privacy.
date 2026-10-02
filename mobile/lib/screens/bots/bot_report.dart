import 'package:flutter/material.dart';
import '../../services/bot_service.dart';

/// "Report bot" sheet. One report per person per bot. Enough different people
/// reporting a bot suspends it automatically until an admin has looked.
Future<void> showReportBotDialog(BuildContext context, String username) async {
  String reason = 'spam';
  final details = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        icon: const Icon(Icons.flag_outlined),
        title: Text('Report @$username'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in BotService.reportReasons.entries)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: e.key,
                  groupValue: reason,
                  title: Text(e.value),
                  onChanged: (v) => setD(() => reason = v ?? reason),
                ),
              const SizedBox(height: 6),
              TextField(
                controller: details,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Details (optional)', border: OutlineInputBorder()),
              ),
              const Text(
                'Your report is private. The bot\'s owner is not told who reported it.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send report')),
        ],
      ),
    ),
  );
  final text = details.text.trim();
  details.dispose();
  if (ok != true) return;
  try {
    await BotService.instance.report(username, reason, details: text);
    messenger.showSnackBar(const SnackBar(content: Text('Thanks — your report was sent.')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
  }
}
