import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../services/call_privacy_service.dart';
import '../../services/call_quality_service.dart';
import '../../services/call_service.dart';

/// Settings > Calls. Right now it holds one setting, "Protect IP address in
/// calls" (see CallPrivacyService for what it does). Written like WhatsApp's:
/// off by default, and turning it on shows a clear warning first.
class CallSettingsScreen extends StatefulWidget {
  const CallSettingsScreen({super.key});

  @override
  State<CallSettingsScreen> createState() => _CallSettingsScreenState();
}

class _CallSettingsScreenState extends State<CallSettingsScreen> {
  bool _relay = CallPrivacyService.relayOnly;
  bool _lowData = CallQualityService.lowData;
  bool _recordingAlerts = CallQualityService.recordingAlerts;

  @override
  void initState() {
    super.initState();
    CallQualityService.load().then((_) {
      if (mounted) {
        setState(() {
          _lowData = CallQualityService.lowData;
          _recordingAlerts = CallQualityService.recordingAlerts;
        });
      }
    });
  }

  bool get _available => CallService.isTurnConfigured;

  Future<void> _toggle(bool turnOn) async {
    if (turnOn) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: Text(context.tr('Protect your IP address?')),
          content: Text(
            context.tr(
              'Your calls will go through a relay server so the other person can\'t see your IP address.\n\n'
              'Because the audio takes a longer route, calls may have more delay and lower sound quality, and may use '
              'more mobile data. If a call won\'t connect, come back here and turn this off.',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(context.tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(context.tr('Turn on'))),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await CallPrivacyService.setRelayOnly(turnOn);
    if (mounted) setState(() => _relay = turnOn);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Calls'))),
      body: ListView(
        children: [
          // Feature: low-data mode.
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.data_saver_on_outlined),
            title: Text(context.tr('Low-data mode')),
            subtitle: Text(
              context.tr(
                'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.',
              ),
            ),
            value: _lowData,
            onChanged: (v) async {
              await CallQualityService.setLowData(v);
              if (mounted) setState(() => _lowData = v);
            },
          ),
          // Feature: recording alerts.
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.fiber_manual_record_outlined),
            title: Text(context.tr('Recording alerts')),
            subtitle: Text(
              context.tr(
                'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.',
              ),
            ),
            value: _recordingAlerts,
            onChanged: (v) async {
              await CallQualityService.setRecordingAlerts(v);
              if (mounted) setState(() => _recordingAlerts = v);
            },
          ),
          const Divider(height: 1),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.shield_outlined),
            title: Text(context.tr('Protect IP address in calls')),
            subtitle: Text(
              context.tr(
                'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.',
              ),
            ),
            value: _relay && _available,
            onChanged: _available ? _toggle : null,
          ),
          if (!_available)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: scheme.onSurfaceVariant, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr('Not available in this version of the app — it has no relay server set up.'),
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          if (_available && _relay)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
              child: Text(
                context.tr('On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.'),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}
