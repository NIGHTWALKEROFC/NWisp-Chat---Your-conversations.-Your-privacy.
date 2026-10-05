import 'package:flutter/material.dart';
import '../services/reminder_service.dart';

/// "Remind me later" for one message: pick a time, and a notification is
/// scheduled. Used from both the 1:1 and the group chat screens.
Future<void> askReminder(
  BuildContext context, {
  required String messageId,
  required String conversationId,
  required String peerUid,
  required String peerName,
  required String preview,
}) async {
  final now = DateTime.now();
  DateTime tomorrow9 = DateTime(now.year, now.month, now.day + 1, 9);
  DateTime tonight8 = DateTime(now.year, now.month, now.day, 20);
  final options = <(String, DateTime)>[
    ('In 20 minutes', now.add(const Duration(minutes: 20))),
    ('In 1 hour', now.add(const Duration(hours: 1))),
    ('In 3 hours', now.add(const Duration(hours: 3))),
    if (tonight8.isAfter(now.add(const Duration(minutes: 30)))) ('This evening, 8:00 PM', tonight8),
    ('Tomorrow, 9:00 AM', tomorrow9),
  ];
  final picked = await showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('Remind me', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
          ),
          for (final o in options)
            ListTile(
              leading: const Icon(Icons.alarm),
              title: Text(o.$1),
              onTap: () => Navigator.pop(ctx, o.$2),
            ),
          ListTile(
            leading: const Icon(Icons.edit_calendar_outlined),
            title: const Text('Pick date and time…'),
            onTap: () async {
              final date = await showDatePicker(
                context: ctx,
                initialDate: now,
                firstDate: now,
                lastDate: now.add(const Duration(days: 365)),
              );
              if (date == null || !ctx.mounted) return;
              final time = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
              if (time == null || !ctx.mounted) return;
              Navigator.pop(ctx, DateTime(date.year, date.month, date.day, time.hour, time.minute));
            },
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  if (!picked.isAfter(DateTime.now())) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a time in the future.')));
    return;
  }
  final ok = await ReminderService.instance.add(
    messageId: messageId,
    conversationId: conversationId,
    peerUid: peerUid,
    peerName: peerName,
    preview: preview,
    at: picked,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(ok ? "Okay, I'll remind you at ${TimeOfDay.fromDateTime(picked).format(context)} on ${picked.day}/${picked.month}" : 'Allow notifications for NWisp first (Settings → Permissions).'),
  ));
}
