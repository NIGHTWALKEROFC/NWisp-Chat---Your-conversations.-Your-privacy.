import 'package:flutter/material.dart';
import '../../widgets/contact_developer_sheet.dart';

class _FaqItem {
  final String question;
  final String answer;
  const _FaqItem(this.question, this.answer);
}

const _faqs = [
  _FaqItem(
    'I forgot my password. What do I do?',
    "Go to the login screen and tap 'Forgot password?', or open Account settings "
        "inside the app and tap 'Forgot your password?'. We'll email you a secure "
        'reset link.',
  ),
  _FaqItem(
    'I forgot my app lock PIN.',
    "On the lock screen, tap 'Forgot PIN?' and confirm your account password "
        '(or reset your account password first if you\'ve forgotten that too). '
        "This turns app lock off so you can get back in, and you'll be asked to "
        'set a new PIN afterwards.',
  ),
  _FaqItem(
    'Why do messages disappear?',
    'This app auto-deletes messages after a set time to protect your privacy. '
        'You can change the default in Settings, or set a different duration for '
        "just one chat from that chat's settings screen.",
  ),
  _FaqItem(
    'Can I change my username or email?',
    'Yes, both are in Account settings. Email changes require your current password '
        'and a confirmation link sent to the new address.',
  ),
];

class HelpCenterScreen extends StatelessWidget {
  const HelpCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help Centre')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Frequently asked questions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...(_faqs.map(
            (faq) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                title: Text(faq.question, style: const TextStyle(fontWeight: FontWeight.w600)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(faq.answer, style: TextStyle(color: scheme.onSurfaceVariant))],
              ),
            ),
          )),
          const SizedBox(height: 16),
          Card(
            color: scheme.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.support_agent_outlined, color: scheme.onPrimaryContainer),
              title: Text('Still need help?', style: TextStyle(color: scheme.onPrimaryContainer)),
              subtitle: Text('Contact the developer directly', style: TextStyle(color: scheme.onPrimaryContainer)),
              onTap: () => showContactDeveloperSheet(context),
            ),
          ),
        ],
      ),
    );
  }
}
