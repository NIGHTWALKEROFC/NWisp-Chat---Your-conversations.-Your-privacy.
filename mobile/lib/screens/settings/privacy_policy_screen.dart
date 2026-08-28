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
            body: 'NWisp is a privacy-focused messaging app built around end-to-end encryption. '
                'Every 1:1 and group chat is encrypted using the Signal Protocol (the same core '
                'encryption design used by Signal and, for chats, WhatsApp) — messages are encrypted '
                'on your device and only decrypted on the recipient\'s device. Messages can also '
                'auto-delete after a duration you control (default 24 hours, adjustable per chat), '
                'and Stories you post disappear after 24 hours.',
          ),
          _Section(
            title: '2. The short version: what we can and can\'t see',
            body: '• We CANNOT read your message text, photos, videos, or voice notes — they are '
                'encrypted on your device before they ever leave it, and our servers only ever '
                'hold that encrypted, unreadable data, briefly, in transit.\n'
                '• We CAN see metadata needed to run the service: your username and email, who '
                'your contacts and groups are, when you\'re online (if enabled), which device is '
                'signed in, and basic app-diagnostic info like crash logs if you send one.\n'
                '• We do not run ads, ad tracking, or sell data to advertisers or data brokers of '
                'any kind.',
          ),
          _Section(
            title: '3. Message content, specifically',
            body: 'Each message is encrypted on your device using a unique key pair for that '
                'conversation before it\'s sent (the Signal Protocol\'s "Double Ratchet" design, '
                'which changes the encryption key for every message). The encrypted message '
                'briefly passes through our relay server just long enough to reach the recipient\'s '
                'device, then it is deleted from that relay — it is not kept, backed up, or logged '
                'there. Your own copy of every message is stored only on your device, encrypted at '
                'rest with a key that never leaves that device. If you sign out, switch devices, or '
                'uninstall the app, that local copy is gone — we do not keep a server-side backup of '
                'your message history, and we could not decrypt one even if we did.',
          ),
          _Section(
            title: '4. Verifying who you\'re talking to',
            body: 'Because we can\'t read your messages, we also can\'t verify for you that a chat '
                'hasn\'t been intercepted — that\'s what the "Verify safety number" feature in each '
                'chat\'s settings is for. Comparing that number with the other person through a '
                'trusted channel (in person, on a call) is the strongest confirmation available '
                'that your conversation is private between only the two of you. The app also warns '
                'you automatically if a contact\'s encryption key changes unexpectedly (for example, '
                'if they reinstalled the app).',
          ),
          _Section(
            title: '5. Account and profile information',
            body: '• Account info: your username and email address, used to sign in and to let '
                'contacts find and message you.\n'
                '• Profile photo, if you add one.\n'
                '• Your contacts list and group memberships (who you\'re connected to, not the '
                'content of what you say to them).\n'
                '• A push-notification token for your device, used only to alert you to a new '
                'message (the notification itself never contains message content — see section 8).\n'
                '• Presence info (online/offline, last seen), only if you\'ve left that visible in '
                'Settings.\n'
                '• We do not collect your phone number, and do not access your phone\'s contact '
                'book.',
          ),
          _Section(
            title: '6. Login activity and approximate location',
            body: 'Every time you sign in, or change your password, we record the device model and '
                'an approximate location (city/country) for that login, shown to you in Settings > '
                'Account security — this is the same kind of "where you\'re signed in" list Google, '
                'WhatsApp, and most banking apps show, so you can spot a login that wasn\'t you. The '
                'location is looked up from your device\'s IP address at the moment of login using a '
                'third-party IP-geolocation lookup (ipapi.co) — it is a rough, city-level estimate, '
                'not GPS or precise location, and we do not track your location at any other time. '
                'This history is visible only to you, and you can clear it from that same screen at '
                'any time (clearing it hides old entries from your view — see section 11 for how the '
                'underlying record is handled).',
          ),
          _Section(
            title: '7. Groups',
            body: 'A group\'s name, description, photo, and member list are visible to every member '
                'of that group, and stored so the app can show who\'s in a group and manage '
                'admin/owner permissions. Group messages are end-to-end encrypted the same way 1:1 '
                'messages are — a separate encrypted copy is created for each member\'s device, and '
                'we cannot read group message content any more than we can read a 1:1 chat. If an '
                'admin invites someone who isn\'t already your contact, that person sees a request '
                'they must accept before they\'re added or can see anything about the group.',
          ),
          _Section(
            title: '8. Notifications',
            body: 'Push notifications are delivered through Firebase Cloud Messaging and only ever '
                'contain a sender\'s username and a generic line like "Sent you a message" — never '
                'the actual message text, photo, or voice content, since we don\'t have access to it '
                'to put in a notification in the first place. If you mute a chat or group, no '
                'notification is sent for it at all.',
          ),
          _Section(
            title: '9. Media (photos, videos, voice messages)',
            body: 'Media is encrypted on your device with a random one-time key before upload. Only '
                'the encrypted file is stored, briefly, on our media server (Supabase Storage) — '
                'just long enough for the recipient to download and decrypt it — and it is deleted '
                'afterward for 1:1 chats. Story media follows the same encrypted-upload approach and '
                'is automatically removed 24 hours after posting.',
          ),
          _Section(
            title: '10. Screenshots and screen recording',
            body: 'Chat and group chat screens use Android\'s screenshot-blocking protection '
                '(FLAG_SECURE) by default, the same mechanism Signal and WhatsApp use — this blocks '
                'both screenshots and screen recording of those screens at the operating-system '
                'level, and also hides chat content from the "recent apps" preview thumbnail.',
          ),
          _Section(
            title: '11. How long we keep things',
            body: '• Message content: only ever on your own device, for as long as you keep it or '
                'until its auto-delete timer expires — never retained by us.\n'
                '• In-transit relay data: deleted immediately once delivered, typically within '
                'seconds.\n'
                '• Account/profile data: kept while your account exists.\n'
                '• Login-activity history: kept so a security-relevant record exists (see section '
                '6), but hidden from your own view once you clear it; a security log entry is not '
                'deleted outright the way a message is, so that evidence of a genuine unauthorized '
                'login can\'t be erased by whoever caused it.\n'
                '• You can request full account deletion at any time — see section 14.',
          ),
          _Section(
            title: '12. Who can see your information',
            body: 'Only people you accept as contacts (or accept a group invite from) can message '
                'you or see your presence info, and only if you\'ve chosen to make that visible in '
                'Settings. We do not sell or share your data with advertisers or data brokers.',
          ),
          _Section(
            title: '13. Your choices',
            body: '• Change your email, username, or photo at any time in Account settings.\n'
                '• Turn off last-seen and read-receipt visibility in Settings.\n'
                '• Set a shorter (or no) auto-delete duration, app-wide or per chat/group.\n'
                '• Mute, archive, or pin any chat or group.\n'
                '• Enable an app-lock PIN for extra on-device protection.\n'
                '• Clear a chat (removes it from your device only) or clear it for both sides.\n'
                '• Block or report a contact.\n'
                '• Delete your account entirely.',
          ),
          _Section(
            title: '14. Deleting your account',
            body: 'You can request full account deletion by contacting us at the email below. This '
                'removes your account, profile, and Firestore data associated with it. Since message '
                'content is never stored on our servers to begin with, there is no server-side '
                'message history to delete — only what remains on your own and your contacts\' '
                'devices, which is outside our control once delivered.',
          ),
          _Section(
            title: '15. Where data is processed',
            body: 'Account data and metadata are stored with Firebase (Google Cloud); the encrypted '
                'message relay and media storage run on Supabase; login-location lookups use ipapi.co. '
                'All three providers encrypt data in transit (TLS) and at rest on their own '
                'infrastructure.',
          ),
          _Section(
            title: '16. Children',
            body: 'This app is not directed at children, and is not knowingly used to collect '
                'information from children under the applicable age of consent in their country.',
          ),
          _Section(
            title: '17. Changes to this policy',
            body: 'We\'ll update the date at the top of this page whenever this policy changes. '
                'Continuing to use the app after a change means you accept the update.',
          ),
          _Section(
            title: '18. Contact',
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
