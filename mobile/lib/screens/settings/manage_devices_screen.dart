import 'package:flutter/material.dart';
import '../../services/device_session_service.dart';
import '../../services/signal_session_service.dart';

/// Feature: multiple devices (off by default). Lists every device
/// currently allowed to sign in to this account, with the primary
/// (messaging-capable) one marked, and lets any of them be removed.
///
/// Used two ways:
///  * Normally, pushed from Account security > Multiple devices — just a
///    management screen, closable any time.
///  * As a blocking step during login, when a new device hits the
///    person's own device limit (see LoginScreen catching
///    DeviceLimitReachedException) — [blockingLimit] is set, the screen
///    opens with an explanatory banner and a Cancel button, and pops
///    `true` the moment a device is removed (so the login can retry) or
///    `false`/null if the person backs out instead.
class ManageDevicesScreen extends StatefulWidget {
  final String uid;
  final int? blockingLimit;
  const ManageDevicesScreen({super.key, required this.uid, this.blockingLimit});

  @override
  State<ManageDevicesScreen> createState() => _ManageDevicesScreenState();
}

class _ManageDevicesScreenState extends State<ManageDevicesScreen> {
  bool _busy = false;

  String _timeAgo(DateTime? time) {
    if (time == null) return 'just now';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _revoke(LinkedDevice device) async {
    final isBlocking = widget.blockingLimit != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(device.isThisDevice ? 'Sign this device out?' : 'Remove "${device.label}"?'),
        content: Text(
          device.isThisDevice
              ? "You'll need to sign in again on this device."
              : 'That device will be signed out immediately.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(device.isThisDevice ? 'Sign out' : 'Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await DeviceSessionService.instance.revokeDevice(widget.uid, device.deviceId);
      if (!mounted) return;
      if (isBlocking) {
        Navigator.pop(context, true);
        return;
      }
      if (device.isThisDevice) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOutOthers(int count) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out all other devices?'),
        content: Text(
          count == 1
              ? 'The other device will be signed out immediately. This device stays signed in.'
              : 'The other $count devices will be signed out immediately. This device stays signed in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign them out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final removed = await DeviceSessionService.instance.signOutOtherDevices(widget.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(removed == 0 ? 'No other devices were signed in.' : 'Signed out $removed other device${removed == 1 ? '' : 's'}.')),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _makePrimary(LinkedDevice device) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Make this the primary device?'),
        content: Text(
          'Messages will start being encrypted to "${device.label}" instead. This works exactly like reinstalling the app on '
          "it: your contacts' apps will show that your encryption key changed, and may want to re-verify with you.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Make primary')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!device.isThisDevice) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open this on "${device.label}" itself to make it primary — the key has to be generated there.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await SignalSessionService.instance.resetIdentityOnThisDevice();
      await DeviceSessionService.instance.makeThisDevicePrimary(widget.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This device is now primary for messaging.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't switch — check your connection and try again.")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocking = widget.blockingLimit;
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Devices'),
          automaticallyImplyLeading: blocking == null,
          leading: blocking != null
              ? IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context, false))
              : null,
        ),
        body: StreamBuilder<List<LinkedDevice>>(
          stream: DeviceSessionService.instance.devicesStream(widget.uid),
          builder: (context, snapshot) {
            final devices = snapshot.data;
            if (devices == null) return const Center(child: CircularProgressIndicator());
            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (blocking != null)
                  Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.devices_other_outlined, color: scheme.onErrorContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "You've reached your device limit ($blocking). Remove one below to finish signing in here.",
                            style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Devices allowed to sign in to this account at the same time. Only the primary device can send and '
                      'receive messages — see Multiple devices in Account security for why.',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                // One-tap clean-up: only shown when there IS another device,
                // and never in the blocking "device limit" step during login.
                if (blocking == null && devices.any((d) => !d.isThisDevice))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _signOutOthers(devices.where((d) => !d.isThisDevice).length),
                      icon: Icon(Icons.logout, color: scheme.error),
                      label: Text('Sign out all other devices', style: TextStyle(color: scheme.error)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
                      ),
                    ),
                  ),
                for (final device in devices)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            leading: Icon(Icons.phone_android, color: device.isThisDevice ? scheme.primary : scheme.onSurfaceVariant),
                            title: Row(
                              children: [
                                Flexible(child: Text(device.label, overflow: TextOverflow.ellipsis)),
                                if (device.isThisDevice) ...[
                                  const SizedBox(width: 6),
                                  Text('(this device)', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              '${device.isPrimary ? "Primary — sends and receives messages" : "Can't open chats yet"} • '
                              '${device.location ?? 'Unknown location'} • active ${_timeAgo(device.lastActiveAt)}',
                            ),
                            trailing: device.isPrimary ? Icon(Icons.verified, color: scheme.primary, size: 20) : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 6),
                            child: Row(
                              children: [
                                if (!device.isPrimary)
                                  TextButton(
                                    onPressed: _busy ? null : () => _makePrimary(device),
                                    child: const Text('Make primary'),
                                  ),
                                const Spacer(),
                                TextButton(
                                  onPressed: _busy ? null : () => _revoke(device),
                                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                                  child: Text(device.isThisDevice ? 'Sign out' : 'Remove'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
