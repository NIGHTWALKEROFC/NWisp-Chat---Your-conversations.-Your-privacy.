import 'package:flutter/material.dart';
import '../../services/reminder_service.dart';

/// Settings → Reminders: the messages you asked to be reminded about.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  @override
  void initState() {
    super.initState();
    ReminderService.instance.load();
  }

  static String _fmt(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day}/${t.month}/${t.year}  $h:$m ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: ValueListenableBuilder<List<Reminder>>(
        valueListenable: ReminderService.instance.items,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No reminders.\nSelect a message in any chat and tap the alarm icon to be reminded later.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final r = list[i];
              return ListTile(
                leading: CircleAvatar(backgroundColor: scheme.primaryContainer, child: Icon(Icons.alarm, color: scheme.onPrimaryContainer)),
                title: Text(r.peerName, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${r.preview}\n${_fmt(r.at)}', maxLines: 3, overflow: TextOverflow.ellipsis),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel reminder',
                  onPressed: () => ReminderService.instance.cancel(r.id),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
