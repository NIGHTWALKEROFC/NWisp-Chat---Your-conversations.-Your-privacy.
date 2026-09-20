import 'package:flutter/material.dart';

/// What the person chose in [showScheduleSendSheet].
class ScheduleChoice {
  final DateTime sendAt;

  /// Send it without a notification on the recipient's phone.
  final bool silent;

  const ScheduleChoice({required this.sendAt, required this.silent});
}

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime t) {
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour12:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "Today 8:00 PM" / "Tomorrow 9:00 AM" / "Sep 24, 3:30 PM" — used by the
/// picker, the chat's "scheduled" banner and the scheduled-messages list.
String formatScheduledTime(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today ${_clock(t)}';
  if (diff == 1) return 'Tomorrow ${_clock(t)}';
  return '${months[t.month - 1]} ${t.day}, ${_clock(t)}';
}

class _SheetResult {
  final DateTime? at; // null => "pick my own"
  final bool silent;
  const _SheetResult({required this.at, required this.silent});
}

/// Feature: "Send later". Bottom sheet with a few quick times, "Pick date &
/// time…", and a "Send silently" switch (a scheduled message can also be
/// silent). Resolves to null if dismissed.
Future<ScheduleChoice?> showScheduleSendSheet(BuildContext context) async {
  final picked = await showModalBottomSheet<_SheetResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _ScheduleSheet(),
  );
  if (picked == null) return null;
  if (picked.at != null) return ScheduleChoice(sendAt: picked.at!, silent: picked.silent);

  // "Pick date & time…"
  if (!context.mounted) return null;
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: now.add(const Duration(hours: 1)),
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 365)),
    helpText: 'Send on',
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    helpText: 'Send at',
  );
  if (time == null || !context.mounted) return null;

  final chosen = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (chosen.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pick a time in the future.')),
    );
    return null;
  }
  return ScheduleChoice(sendAt: chosen, silent: picked.silent);
}

class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet();

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  bool _silent = false;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final inOneHour = now.add(const Duration(hours: 1));
    final tonight = DateTime(now.year, now.month, now.day, 20);
    final tomorrowMorning = DateTime(now.year, now.month, now.day + 1, 9);

    Widget option(IconData icon, String title, DateTime? at) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: at == null ? null : Text(formatScheduledTime(at)),
        onTap: () => Navigator.pop(context, _SheetResult(at: at, silent: _silent)),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Send later', style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            option(Icons.schedule, 'In 1 hour', inOneHour),
            if (tonight.isAfter(now.add(const Duration(minutes: 30)))) option(Icons.nights_stay_outlined, 'This evening', tonight),
            option(Icons.wb_sunny_outlined, 'Tomorrow morning', tomorrowMorning),
            option(Icons.edit_calendar_outlined, 'Pick date & time…', null),
            const Divider(),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.notifications_off_outlined),
              title: const Text('Send silently'),
              subtitle: const Text('No notification on their phone when it arrives'),
              value: _silent,
              onChanged: (v) => setState(() => _silent = v),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'NWisp sends it from this phone at that time (messages are encrypted on your phone, so nothing can send it for you). '
                'If the app is closed then, it sends when you next open it — up to 2 hours late. After that it waits for you to send or delete it.',
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
