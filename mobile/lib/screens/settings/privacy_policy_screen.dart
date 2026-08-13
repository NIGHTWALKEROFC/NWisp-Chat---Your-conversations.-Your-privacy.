import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _lastUpdated = 'August 2026';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Last updated: $_lastUpdated', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          _Section(
            title: '1. What this app is',
            body: 'NWisp is a privacy-focused messaging app. Messages are automatically '
                "deleted after a duration you control (default 24 hours), and 'Stories' "
                'you post disappear after 24 hours.',
          ),
          _Section(
            title: '2. Information we collect',
            body: '• Account info: username, email address, and (if you choose to add one) '
                'phone number.\n'
                '• Content you create: messages, media you send, and Stories, for as long as '
                'their auto-delete timer allows.\n'
                '• Device info: a push-notification token for your device, and basic presence '
                'info (online/offline, last seen) if you have that visible in your privacy settings.\n'
                "• We do not collect your precise location, and we don't run ads or ad tracking.",
          ),
          _Section(
            title: '3. How we store it',
            body: 'Account data and messages are stored with Firebase (Google Cloud) and media '
                'files are stored with Supabase. Both providers encrypt data in transit (TLS) '
                'and at rest on their infrastructure. Messages are removed automatically after '
                'the auto-delete duration for that chat expires.',
          ),
          _Section(
            title: '4. Who can see your information',
            body: 'Only people you accept as contacts can message you or see your presence '
                'info, and only if you\'ve chosen to make that visible in Settings. We do not '
                'sell or share your data with advertisers or data brokers.',
          ),
          _Section(
            title: '5. Your choices',
            body: '• You can change or remove your email, phone number, username, and photo at '
                'any time in Account settings.\n'
                '• You can turn off last-seen and read-receipt visibility in Settings.\n'
                "• You can set a shorter auto-delete duration app-wide or per chat.\n"
                '• You can clear a chat, block a contact, or delete your account by contacting '
                'the developer.',
          ),
          _Section(
            title: '6. Security',
            body: 'Changing your email or phone number requires confirming your current '
                'password, and phone number changes additionally require verifying a one-time '
                'code sent by SMS. An optional local app-lock PIN is available for extra '
                'protection on your device.',
          ),
          _Section(
            title: '7. Children',
            body: 'This app is not directed at children, and is not knowingly used to collect '
                'information from children under the applicable age of consent in their country.',
          ),
          _Section(
            title: '8. Changes to this policy',
            body: "We'll update the date at the top of this page whenever this policy changes. "
                'Continuing to use the app after a change means you accept the update.',
          ),
          _Section(
            title: '9. Contact',
            body: 'Questions about this policy or your data can be sent to rinshan602@gmail.com.',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        ],
      ),
    );
  }
}
