import 'package:flutter/material.dart';

/// Units the custom-duration dialog can offer.
enum DurationUnit { minutes, hours, days }

/// Human-readable label for a duration, picking the largest unit that
/// divides it evenly: 1 day, 2 hours, 45 minutes. Used by the mute picker,
/// the app-lock timing pickers, and anywhere else a custom value needs to
/// be shown back to the person.
String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  if (minutes >= 1440 && minutes % 1440 == 0) {
    final days = minutes ~/ 1440;
    return '$days day${days == 1 ? '' : 's'}';
  }
  if (minutes >= 60 && minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return '$hours hour${hours == 1 ? '' : 's'}';
  }
  return '$minutes minute${minutes == 1 ? '' : 's'}';
}

/// Shows a small dialog asking for "a number + a unit" and returns the
/// result as a [Duration], or null if the person cancelled.
///
/// [min] / [max] are enforced with an inline error message, so the caller
/// never has to deal with a zero, negative, or absurdly large value.
Future<Duration?> showCustomDurationDialog(
  BuildContext context, {
  required String title,
  String? helperText,
  List<DurationUnit> units = const [DurationUnit.minutes, DurationUnit.hours, DurationUnit.days],
  DurationUnit initialUnit = DurationUnit.hours,
  int initialValue = 1,
  Duration min = const Duration(minutes: 1),
  Duration max = const Duration(days: 365),
}) {
  return showDialog<Duration>(
    context: context,
    builder: (_) => _CustomDurationDialog(
      title: title,
      helperText: helperText,
      units: units,
      initialUnit: initialUnit,
      initialValue: initialValue,
      min: min,
      max: max,
    ),
  );
}

class _CustomDurationDialog extends StatefulWidget {
  final String title;
  final String? helperText;
  final List<DurationUnit> units;
  final DurationUnit initialUnit;
  final int initialValue;
  final Duration min;
  final Duration max;

  const _CustomDurationDialog({
    required this.title,
    required this.helperText,
    required this.units,
    required this.initialUnit,
    required this.initialValue,
    required this.min,
    required this.max,
  });

  @override
  State<_CustomDurationDialog> createState() => _CustomDurationDialogState();
}

class _CustomDurationDialogState extends State<_CustomDurationDialog> {
  late final TextEditingController _controller = TextEditingController(text: '${widget.initialValue}');
  late DurationUnit _unit = widget.units.contains(widget.initialUnit) ? widget.initialUnit : widget.units.first;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Duration _toDuration(int n, DurationUnit unit) {
    switch (unit) {
      case DurationUnit.minutes:
        return Duration(minutes: n);
      case DurationUnit.hours:
        return Duration(hours: n);
      case DurationUnit.days:
        return Duration(days: n);
    }
  }

  String _unitLabel(DurationUnit unit) {
    switch (unit) {
      case DurationUnit.minutes:
        return 'Minutes';
      case DurationUnit.hours:
        return 'Hours';
      case DurationUnit.days:
        return 'Days';
    }
  }

  void _submit() {
    final n = int.tryParse(_controller.text.trim());
    if (n == null || n <= 0) {
      setState(() => _error = 'Enter a whole number greater than 0');
      return;
    }
    final d = _toDuration(n, _unit);
    if (d < widget.min) {
      setState(() => _error = 'Must be at least ${formatDuration(widget.min)}');
      return;
    }
    if (d > widget.max) {
      setState(() => _error = 'Must be no more than ${formatDuration(widget.max)}');
      return;
    }
    Navigator.pop(context, d);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.helperText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(widget.helperText!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            maxLength: 5,
            decoration: InputDecoration(labelText: 'Amount', counterText: '', errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          SegmentedButton<DurationUnit>(
            segments: [
              for (final u in widget.units) ButtonSegment<DurationUnit>(value: u, label: Text(_unitLabel(u))),
            ],
            selected: {_unit},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              _unit = s.first;
              _error = null;
            }),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}
