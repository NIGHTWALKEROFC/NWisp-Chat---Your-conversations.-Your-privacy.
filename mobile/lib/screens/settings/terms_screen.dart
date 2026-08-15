import 'package:flutter/material.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const _lastUpdated = 'August 2026';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Terms & Conditions')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Last updated: $_lastUpdated', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          _Section(
            title: '1. Acceptance',
            body: 'By creating an account you agree to these Terms and to the Privacy Policy. '
                "If you don't agree, please don't use NWisp.",
          ),
          _Section(
            title: '2. The service',
            body: 'NWisp is a free, ad-free, privacy-focused messaging app. Messages disappear '
                "after the auto-delete duration you set (default 24 hours). There's no guaranteed "
                'uptime or support level — this is a small, independently run app.',
          ),
          _Section(
            title: '3. Your account',
            body: "You're responsible for keeping your password and device secure. You must be old "
                "enough to consent to online services in your country. One account per person — don't "
                'impersonate someone else or create accounts to evade a block or ban.',
          ),
          _Section(
            title: '4. Acceptable use',
            body: "Don't use NWisp to harass, threaten, or abuse others; send illegal content; spam; "
                'attempt to break the encryption, security, or infrastructure; or use it in any way '
                'that violates the law where you live. Accounts found doing this may be blocked or '
                'removed.',
          ),
          _Section(
            title: '5. Content is yours',
            body: "You own what you send. Because of NWisp's design, message content is never "
                'readable by the server and is deleted from it as soon as it reaches the recipient '
                "— so there's no way for us to recover, moderate, or restore lost messages after the "
                'fact. See the Privacy Policy for exactly what is and isn\'t stored.',
          ),
          _Section(
            title: '6. No warranty',
            body: 'NWisp is provided "as is," without warranties of any kind. Auto-delete timing, '
                'delivery, and encryption are implemented carefully but not guaranteed to be perfect '
                '— see the known-limitations notes in the in-app Help Centre.',
          ),
          _Section(
            title: '7. Termination',
            body: 'You can stop using NWisp and request account deletion at any time by contacting '
                'the developer. Accounts that violate these Terms may be suspended or removed.',
          ),
          _Section(
            title: '8. Changes',
            body: "These Terms may change as the app changes. We'll update the date at the top of "
                'this page — continuing to use the app after a change means you accept the update.',
          ),
          _Section(
            title: '9. Contact',
            body: 'Questions about these Terms can be sent to rinshan602@gmail.com.',
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
