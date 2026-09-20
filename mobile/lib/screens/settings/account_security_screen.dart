import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
import '../../services/moderation_service.dart';
import 'forgot_password_screen.dart';

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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Password reset', style: Theme.of(context).textTheme.titleSmall),
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('profile').snapshots(),
            builder: (context, snapshot) {
              final method = (snapshot.data?.data()?['passwordResetMethod'] as String?) ?? 'email';
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: const Icon(Icons.password_outlined),
                  title: const Text('Password reset method'),
                  subtitle: Text(
                    method == 'otp'
                        ? 'Email a 6-digit code — you type it in the app along with a new password'
                        : 'Email a "Reset your password" button — the default',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final choice = await showDialog<String>(
                      context: context,
                      builder: (dialogContext) => SimpleDialog(
                        title: const Text('Password reset method'),
                        children: [
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(dialogContext, 'email'),
                            child: Row(
                              children: [
                                Icon(method == 'email' ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                                const SizedBox(width: 12),
                                const Expanded(child: Text('Email link (default)')),
                              ],
                            ),
                          ),
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(dialogContext, 'otp'),
                            child: Row(
                              children: [
                                Icon(method == 'otp' ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                                const SizedBox(width: 12),
                                const Expanded(child: Text('Email code (OTP)')),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                    if (choice != null && choice != method) {
                      await AuthService().updatePasswordResetMethod(choice);
                    }
                  },
                ),
              );
            },
          ),
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
