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
        "inside the app and tap 'Not sure this was you?' under Account security. We'll "
        'email you a secure reset link.',
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
        "just one chat or group from that chat's settings/group info screen.",
  ),
  _FaqItem(
    'Are my messages actually encrypted?',
    'Yes — every 1:1 and group chat uses the Signal Protocol, the same core end-to-end '
        'encryption design Signal uses. Messages are encrypted on your device and only '
        'decrypted on the recipient\'s device; we never have access to the readable text, '
        'photos, videos, or voice notes you send.',
  ),
  _FaqItem(
    "What's a safety number, and why would I check it?",
    "It's a way to manually confirm you're really talking to the person you think you "
        'are, with no one able to secretly intercept the conversation. Open a chat\'s '
        "settings and tap 'Verify safety number' — if the number matches on both your "
        "and the other person's devices (compared in person or on a call), your "
        'conversation is confirmed private.',
  ),
  _FaqItem(
    'Why did I get a "security code changed" warning?',
    'This means the other person\'s encryption key changed — usually because they '
        'reinstalled the app or switched devices, which is completely normal. It can, '
        'rarely, also mean something more concerning, which is exactly why the app warns '
        'you rather than silently continuing — if you\'re ever unsure, use "Verify safety '
        'number" to confirm.',
  ),
  _FaqItem(
    'Can I edit a message after sending it?',
    "Yes, for a short time after sending (currently 15 minutes) — long-press your own "
        "text message and tap Edit. The recipient sees an '(edited)' label so it's never "
        'silent. Media and voice messages can\'t be edited.',
  ),
  _FaqItem(
    "Someone in my group hasn't gotten a message I sent — why?",
    "If a group member hasn't updated the app or has never opened it, their device can't "
        "receive encrypted messages yet — the app queues that message quietly and delivers "
        "it automatically the moment they update, without you needing to do anything. A "
        "different kind of delivery hiccup (like a brief connection issue) instead shows a "
        "'Resend' button you can tap right away.",
  ),
  _FaqItem(
    "Why can't I just add anyone to a group?",
    "You can add your existing contacts to a group directly. For anyone else, the app "
        "sends them an invite they have to accept before they're added — this stops "
        "someone from being silently pulled into a group chat with strangers without "
        "their say-so.",
  ),
  _FaqItem(
    'How does adding a contact by QR code work?',
    "Open Contacts and tap the QR icon — 'My code' shows a code encoding only your "
        "account id (never your username, email, or phone number), and 'Scan' lets you "
        "scan someone else's. It's a faster, more private alternative to searching for "
        'a username.',
  ),
  _FaqItem(
    'Can I mute, archive, or pin a chat?',
    'Yes — long-press any chat or group on your chat list for quick Pin/Mute/Archive/'
        'Delete options, or use the switches inside a chat\'s settings or a group\'s info '
        'screen. Pinned chats stay at the top of your list; archived chats move out of the '
        'main list but still receive messages normally.',
  ),
  _FaqItem(
    'Can I search for an old message?',
    "Yes — open the search icon inside any chat or group to search that conversation's "
        'messages. This searches only your own device (messages are already stored '
        "decrypted-on-demand locally), so it works instantly and offline.",
  ),
  _FaqItem(
    'Will someone know if I screenshot our chat?',
    "The app doesn't currently notify the other person if you take a screenshot. "
        'Chat screens do block screenshots and screen recording by default on your own '
        "device (Android's screenshot-prevention flag), the same protection Signal and "
        'WhatsApp use, but this only prevents captures on that screen — it doesn\'t detect '
        'or notify about attempts.',
  ),
  _FaqItem(
    "Why don't my old messages show up after reinstalling the app or switching phones?",
    "Message content is stored only on your own device by design — it's never kept on "
        "our servers, so we have nothing to restore it from. This is a direct trade-off of "
        "the app's privacy model: nothing we don't have can ever be exposed if our "
        "servers were ever compromised, but it also means there's no cloud backup of "
        'chat history to fall back on.',
  ),
  _FaqItem(
    "What's the device/location info in Account security?",
    "Every sign-in records the device model and an approximate city/country (from your "
        "IP address, not GPS) so you can spot a login that wasn't you — the same idea as "
        "Google's or WhatsApp's own sign-in activity lists. Only one device can be "
        'actively signed in at a time.',
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
