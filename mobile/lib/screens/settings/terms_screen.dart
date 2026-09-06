import 'package:flutter/material.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const _lastUpdated = 'September 2026';

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
            body: 'NWisp is a free, ad-free, privacy-focused messaging app for 1:1 chats, group '
                'chats, and 24-hour Stories, built on end-to-end encryption (the Signal Protocol). '
                "Messages can auto-delete after a duration you set (default 24 hours). There's no "
                'guaranteed uptime or support level — this is a small, independently run app.',
          ),
          _Section(
            title: '3. Your account',
            body: "You're responsible for keeping your password and device secure. You must be old "
                "enough to consent to online services in your country. One account per person — don't "
                'impersonate someone else or create accounts to evade a block or ban. Only one device '
                "can be actively signed in at a time — signing in elsewhere signs the previous device "
                'out, and this is shown to you in Account security along with the device and '
                'approximate location of each sign-in.',
          ),
          _Section(
            title: '4. Contacts and groups',
            body: 'Messaging someone generally requires them to accept a contact request from you '
                'first. A group admin can add an existing contact to a group directly; adding anyone '
                'else requires that person to accept an invite before they join or see anything about '
                'the group. You can leave any group, block any contact, or decline any request at any '
                'time. Group admins can also turn on "Only admins can send messages" for a group — '
                'everyone can still read and react, but sending is limited to admins until that '
                'setting is turned back off.',
          ),
          _Section(
            title: '5. Acceptable use',
            body: "Don't use NWisp to harass, threaten, or abuse others; send illegal content; spam; "
                'attempt to break the encryption, security, or infrastructure; use it to add or invite '
                'people without a legitimate reason to contact them; or use it in any way that '
                'violates the law where you live. The full, specific list of rules — the same list '
                'shown on every in-app "Report" button — is in Community Guidelines. Accounts found '
                'breaking a rule there may be suspended; see §10.',
          ),
          _Section(
            title: '6. Editing and deleting messages',
            body: 'A text message you sent can be edited for a short window after sending, and shows '
                '"(edited)" to the recipient once changed — it is not a way to silently rewrite what '
                'someone already read. "Delete for everyone" removes a message from the recipient\'s '
                'device too; "delete for me" or "delete chat" from the chat list only ever affects '
                'your own device. Neither action can retroactively un-notify someone who already saw '
                'the original message.',
          ),
          _Section(
            title: '7. Verifying contacts and QR codes',
            body: 'The "Verify safety number" and QR-code contact features exist to help you confirm '
                'who you\'re actually talking to. Don\'t use these features to try to identify or '
                'target someone without their consent — a QR code only ever encodes an account id, '
                'never a real name, phone number, or location.',
          ),
          _Section(
            title: '8. Content is yours',
            body: "You own what you send. Because of NWisp's design, message content is never "
                'readable by the server and is deleted from it as soon as it reaches the recipient '
                "— so there's no way for us to recover, moderate, or restore lost messages after the "
                'fact. See the Privacy Policy for exactly what is and isn\'t stored.',
          ),
          _Section(
            title: '9. No warranty',
            body: 'NWisp is provided "as is," without warranties of any kind. Auto-delete timing, '
                'delivery, screenshot prevention, and encryption are implemented carefully but not '
                'guaranteed to be perfect — see the known-limitations notes in the in-app Help Centre.',
          ),
          _Section(
            title: '10. Reports, suspension, and appeals',
            body: 'Anyone can report an account for a specific rule from Community Guidelines, '
                'optionally with details and a photo as proof. Reports are reviewed by a person, not '
                'automatically. If an account is suspended, that account sees the specific rule cited '
                'and can submit a written appeal, optionally with proof — appeals are also reviewed '
                'by a person. If an appeal is found to have been made in bad faith, the appeal option '
                'for that account may be turned off, with an alternate contact method shown instead. '
                "You can also stop using NWisp and request account deletion at any time — from "
                'Account settings, or by contacting the developer.',
          ),
          _Section(
            title: '11. Changes',
            body: "These Terms may change as the app changes. We'll update the date at the top of "
                'this page — continuing to use the app after a change means you accept the update.',
          ),
          _Section(
            title: '12. Contact',
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
