import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
import '../../services/moderation_service.dart';
import 'forgot_password_screen.dart';
import 'manage_devices_screen.dart';

class AccountSecurityScreen extends StatelessWidget {
  const AccountSecurityScreen({super.key});

  static const List<int> _maxDeviceOptions = [1, 2, 3, 4, 5];

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
    final location = data['location'] as String?;
    final ip = data['ip'] as String?;
    final tags = [if (location != null) location, if (ip != null) ip];
    final deviceWithExtras = tags.isNotEmpty ? '$device (${tags.join(' • ')})' : device;
    switch (data['event']) {
      case 'login':
        return 'Signed in on $deviceWithExtras';
      case 'password_changed':
        return 'Password changed from $deviceWithExtras';
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
          // Feature: failed-login lockout — warns if 10+ failed sign-in
          // attempts have hit this account recently from ANY device or
          // network (each individual device/network is already blocked
          // on its own after 3 — this catches someone spreading attempts
          // across many to dodge that).
          FutureBuilder<int>(
            future: AuthService().recentLoginFailureCount(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              if (count < 10) return const SizedBox.shrink();
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.gpp_maybe_outlined, color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$count failed sign-in attempts recently',
                              style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Someone has been trying to sign in to this account. Consider changing your '
                              'password below, and turning on extra security settings on this page.',
                              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: ModerationService().myProfileStream(),
            builder: (context, profileSnapshot) {
              final hideNames = (profileSnapshot.data?.data()?['notificationPrivacyGlobal'] as bool?) ?? false;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Hide name in notifications'),
                  subtitle: Text(
                    hideNames
                        ? 'On for every chat — notifications show "New message" instead of who sent it'
                        : 'Off — you can still turn this on for one specific chat from that chat\'s own settings',
                  ),
                  value: hideNames,
                  onChanged: (v) => ModerationService().setNotificationPrivacyGlobal(v),
                ),
              );
            },
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: ModerationService().myProfileStream(),
            builder: (context, profileSnapshot) {
              final hideContent = (profileSnapshot.data?.data()?['notificationPrivacyHideContentGlobal'] as bool?) ?? false;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SwitchListTile.adaptive(
                  secondary: const Icon(Icons.notifications_off_outlined),
                  title: const Text('Hide message preview'),
                  subtitle: Text(
                    hideContent
                        ? 'On for every chat — notifications never say "Sent you a photo" or similar, just a generic alert'
                        : 'Off — notifications say what kind of message it is (photo, voice message, etc.), just not the name or content',
                  ),
                  value: hideContent,
                  onChanged: (v) => ModerationService().setNotificationContentPrivacyGlobal(v),
                ),
              );
            },
          ),
          const Card(
            margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              leading: Icon(Icons.screenshot_outlined),
              title: Text('Block screenshots'),
              subtitle: Text(
                'Always on for every chat and group — screenshots and screen recording are blocked. This can\'t be turned off, so the other person\'s privacy is never left up to a setting.',
              ),
            ),
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: DeviceSessionService.instance.sessionStream(uid),
            builder: (context, sessionSnapshot) {
              final sessionData = sessionSnapshot.data?.data();
              final label = sessionData?['activeDeviceLabel'] as String? ?? 'This device';
              final location = sessionData?['activeLocation'] as String?;
              final ip = sessionData?['activeIp'] as String?;
              final since = (sessionData?['activeSince'] as Timestamp?)?.toDate();
              final clearedAt = (sessionData?['historyClearedAt'] as Timestamp?)?.toDate();

              final activeTags = [if (location != null) location, if (ip != null) ip];
              final activeSubtitle = activeTags.isNotEmpty
                  ? 'Active device • ${activeTags.join(' • ')} • signed in ${_timeAgo(since)}'
                  : 'Active device • signed in ${_timeAgo(since)}';

              return Column(
                children: [
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: ListTile(
                      leading: Icon(Icons.phone_android, color: scheme.primary),
                      title: Text(label),
                      subtitle: Text(activeSubtitle),
                      trailing: Icon(Icons.check_circle, color: scheme.primary, size: 20),
                    ),
                  ),
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: SwitchListTile.adaptive(
                      secondary: const Icon(Icons.verified_user_outlined),
                      title: const Text('Require approval for new logins'),
                      subtitle: const Text(
                        'A new login must be accepted from this device before it can sign in. '
                        "Off by default — when off, a new login instantly signs this device out, "
                        'same as today.',
                      ),
                      value: (sessionData?['requireLoginApproval'] as bool?) ?? false,
                      onChanged: (v) => DeviceSessionService.instance.setRequireLoginApproval(uid, v),
                    ),
                  ),
                  // Feature: multiple devices — off by default. See
                  // DeviceSessionService's "Multiple devices" section for
                  // exactly what turning this on does and does not do
                  // (only one device at a time can open chats).
                  Builder(builder: (context) {
                    final multiOn = (sessionData?['multiDeviceEnabled'] as bool?) ?? false;
                    final maxDevices = ((sessionData?['maxDevices'] as num?)?.toInt() ?? DeviceSessionService.defaultMaxDevices)
                        .clamp(DeviceSessionService.minDevices, DeviceSessionService.maxDevicesLimit);
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile.adaptive(
                            secondary: const Icon(Icons.devices_other_outlined),
                            title: const Text('Multiple devices'),
                            subtitle: Text(
                              multiOn
                                  ? 'On — up to $maxDevices devices can be signed in at once. Only your primary device opens chats.'
                                  : 'Off — one device at a time, exactly like today. A new sign-in signs this one out.',
                            ),
                            value: multiOn,
                            onChanged: (v) => DeviceSessionService.instance.setMultiDeviceEnabled(uid, v),
                          ),
                          if (multiOn) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                              child: Row(
                                children: [
                                  const Text('Device limit', style: TextStyle(fontWeight: FontWeight.w600)),
                                  const Spacer(),
                                  DropdownButton<int>(
                                    value: maxDevices,
                                    items: [
                                      for (final n in _maxDeviceOptions) DropdownMenuItem(value: n, child: Text('$n')),
                                    ],
                                    onChanged: (n) {
                                      if (n != null) DeviceSessionService.instance.setMaxDevices(uid, n);
                                    },
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                              child: Text(
                                "Only your primary device can send and receive messages — it holds the encryption key that "
                                "makes that possible. Other signed-in devices can manage contacts, groups, Communities, and "
                                "settings, but their chat screens stay blocked with a clear explanation.",
                                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                              ),
                            ),
                            const SizedBox(height: 4),
                            ListTile(
                              leading: const Icon(Icons.devices_outlined),
                              title: const Text('Manage devices'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => ManageDevicesScreen(uid: uid)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
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
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                // Already signed in, so we already know this account's
                // email — no need to make them type it again.
                builder: (_) => ForgotPasswordScreen(knownEmail: AuthService().currentUser?.email),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
