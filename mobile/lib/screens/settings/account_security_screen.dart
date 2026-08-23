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
            builder: (context, snapshot) {
              final data = snapshot.data?.data();
              final label = data?['activeDeviceLabel'] as String? ?? 'This device';
              final since = (data?['activeSince'] as Timestamp?)?.toDate();
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: Icon(Icons.phone_android, color: scheme.primary),
                  title: Text(label),
                  subtitle: Text('Active device • signed in ${_timeAgo(since)}'),
                  trailing: Icon(Icons.check_circle, color: scheme.primary, size: 20),
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Recent activity', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: DeviceSessionService.instance.historyStream(uid),
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
