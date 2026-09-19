import 'package:flutter/material.dart';
import 'duration_picker_dialog.dart';

/// What the person picked in [showMuteDurationSheet].
///
/// [duration] == null means "mute until I turn it back on" (the same
/// forever-mute the app has always had, stored in the `mutedBy` array).
/// A non-null [duration] is a timed mute (stored as `mutedUntil.<uid>`).
class MuteChoice {
  final Duration? duration;
  const MuteChoice.forever() : duration = null;
  const MuteChoice.forDuration(Duration this.duration);

  bool get isForever => duration == null;

  String get label => duration == null ? 'until you turn it back on' : 'for ${formatDuration(duration!)}';
}

const _customMarker = '__custom__';

/// Bottom sheet used by BOTH the swipe-to-mute gesture on the chat list and
/// the "Mute notifications" switches inside chat/group settings, so every
/// way of muting offers the same set of durations.
///
/// Returns null if the person dismissed the sheet without choosing.
Future<MuteChoice?> showMuteDurationSheet(BuildContext context, {String title = 'Mute notifications'}) async {
  final picked = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('1 hour'),
            onTap: () => Navigator.pop(sheetContext, const MuteChoice.forDuration(Duration(hours: 1))),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('8 hours'),
            onTap: () => Navigator.pop(sheetContext, const MuteChoice.forDuration(Duration(hours: 8))),
          ),
          ListTile(
            leading: const Icon(Icons.today_outlined),
            title: const Text('24 hours (1 day)'),
            onTap: () => Navigator.pop(sheetContext, const MuteChoice.forDuration(Duration(hours: 24))),
          ),
          ListTile(
            leading: const Icon(Icons.date_range_outlined),
            title: const Text('1 week'),
            onTap: () => Navigator.pop(sheetContext, const MuteChoice.forDuration(Duration(days: 7))),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Custom…'),
            subtitle: const Text('Pick your own number of minutes, hours or days'),
            onTap: () => Navigator.pop(sheetContext, _customMarker),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text('Always'),
            subtitle: const Text('Until you turn notifications back on'),
            onTap: () => Navigator.pop(sheetContext, const MuteChoice.forever()),
          ),
        ],
      ),
    ),
  );

  if (picked is MuteChoice) return picked;
  if (picked == _customMarker) {
    if (!context.mounted) return null;
    final d = await showCustomDurationDialog(
      context,
      title: 'Mute for…',
      helperText: 'Notifications come back automatically when the time is up.',
      initialUnit: DurationUnit.hours,
      initialValue: 12,
      min: const Duration(minutes: 5),
      max: const Duration(days: 365),
    );
    if (d == null) return null;
    return MuteChoice.forDuration(d);
  }
  return null;
}
