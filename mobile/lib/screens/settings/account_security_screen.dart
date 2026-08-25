import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';

class AccountSecurityScreen extends StatelessWidget {
  const AccountSecurityScreen({super.key});

  String _timeAgo(DateTime? time) {
    if (time == null) return 'just now';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.month}/${time.day}/${time.year}';
  }

  IconData _iconFor(String event) {
    switch (event) {
      case 'login':
        return Icons.login;
      case 'password_changed':
        return Icons.password_outlined;
      default:
        return Icons.security;
    }
  }

  String _labelFor(Map<String, dynamic> data) {
    final device = data['deviceLabel'] as String? ?? 'a device';
    switch (data['event']) {
      case 'login':
        return 'Signed in on $device';
      case 'password_changed':
        return 'Password changed from $device';
      default:
        return 'Security event';
    }
  }

  Future<void> _confirmClear(BuildContext context, String uid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear activity?'),
        content: const Text(
          'This just hides older entries from this list — it does not undo any sign-in and '
          "doesn't affect your account's actual security.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) {
      await DeviceSessionService.instance.clearHistoryView(uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = AuthService().currentUserId;
    final scheme = Theme.of(context).colorScheme;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Account security')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Only one device can be signed in at a time. If your account is signed '
              'in somewhere else, that device is automatically signed out here.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: DeviceSessionService.instance.sessionStream(uid),
            builder: (context, sessionSnapshot) {
              final sessionData = sessionSnapshot.data?.data();
              final label = sessionData?['activeDeviceLabel'] as String? ?? 'This device';
              final since = (sessionData?['activeSince'] as Timestamp?)?.toDate();
              final clearedAt = (sessionData?['historyClearedAt'] as Timestamp?)?.toDate();

              return Column(
                children: [
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: ListTile(
                      leading: Icon(Icons.phone_android, color: scheme.primary),
                      title: Text(label),
                      subtitle: Text('Active device • signed in ${_timeAgo(since)}'),
                      trailing: Icon(Icons.check_circle, color: scheme.primary, size: 20),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Recent activity', style: TextStyle(fontWeight: FontWeight.w700)),
                        TextButton(
                          onPressed: () => _confirmClear(context, uid),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: DeviceSessionService.instance.historyStream(uid, after: clearedAt),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final docs = snapshot.data!.docs;
                      if (docs.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('No activity yet')),
                        );
                      }
                      return Column(
                        children: docs.map((doc) {
                          final data = doc.data();
                          final time = (data['timestamp'] as Timestamp?)?.toDate();
                          return ListTile(
                            leading: Icon(_iconFor(data['event'] as String? ?? ''), color: scheme.onSurfaceVariant),
                            title: Text(_labelFor(data)),
                            subtitle: Text(_timeAgo(time)),
                            dense: true,
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              );
            },
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.lock_reset_outlined),
            title: const Text('Not sure this was you?'),
            subtitle: const Text('Change your password to sign out anyone else immediately'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
