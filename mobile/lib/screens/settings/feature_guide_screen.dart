import 'package:flutter/material.dart';

/// Distinct from OnboardingScreen (shown once, on first launch, and never
/// again) — this is a persistent reference, reachable any time from
/// Settings, for someone who wants to look something up later or a
/// returning person who skipped onboarding the first time.
class FeatureGuideScreen extends StatelessWidget {
  const FeatureGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Feature guide')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('Privacy & security', scheme),
          const _FeatureEntry(
            icon: Icons.lock_outline_rounded,
            title: 'End-to-end encryption',
            body: 'Every 1:1 and group message, photo, video, and voice note is encrypted on your '
                'device and only decrypted on the recipient\'s. The relay server never has the keys '
                'needed to read any of it.',
          ),
          const _FeatureEntry(
            icon: Icons.health_and_safety_outlined,
            title: 'Privacy checkup',
            body: 'Settings > Privacy checkup scores how many of 12 privacy and security settings '
                'are on, walks you through them one topic at a time, or turns on everything it safely '
                'can in one tap with "Make it 100% private" — which shows you exactly what will '
                'change before it changes anything, and can be undone afterward. It never turns on '
                'auto-delete or auto-wipe, since those remove data rather than just lock things down.',
          ),
          const _FeatureEntry(
            icon: Icons.pin_outlined,
            title: 'App lock',
            body: 'A PIN you choose yourself, asked every time the app opens. From there you can also '
                'set it to lock the instant you leave, lock itself after a few minutes of no touches, '
                'or lock on a shake of the phone.',
          ),
          const _FeatureEntry(
            icon: Icons.privacy_tip_outlined,
            title: 'Panic PIN',
            body: 'A second PIN you set up that opens a decoy screen instead of your real chats — for '
                'a moment when you\'re asked to unlock your phone and don\'t want to refuse.',
          ),
          const _FeatureEntry(
            icon: Icons.no_photography_outlined,
            title: 'Intruder photo',
            body: 'Off by default. Turn it on in Settings > Security and the front camera quietly '
                'takes a photo after a few wrong app-lock PINs, saved into your Media vault with an '
                '"Intruder" label and the time. A "Test it now" button lets you check your phone '
                'allows it before relying on it — some phones need a visible camera preview to take a '
                'photo at all.',
          ),
          const _FeatureEntry(
            icon: Icons.enhanced_encryption_outlined,
            title: 'Media vault',
            body: 'A separate, PIN-locked space for photos and videos, with its own PIN independent '
                'of your app-lock PIN. Long-press a photo or video in any chat to move it in, or add '
                'one straight from your device. Everything in it stays on your device only.',
          ),
          const _FeatureEntry(
            icon: Icons.visibility_off_outlined,
            title: 'View-once media',
            body: 'Send a photo or video that the recipient can open exactly once before it\'s gone. '
                'Switch it on with the circled-1 button in the photo/video preview screen before '
                'sending.',
          ),
          const _FeatureEntry(
            icon: Icons.timer_outlined,
            title: 'Disappearing messages',
            body: 'Open a chat or group\'s settings to set an auto-delete timer. Once it\'s set, new '
                'messages delete themselves after that much time — set it back to "Never" to keep '
                'everything again.',
          ),
          const _FeatureEntry(
            icon: Icons.verified_user_outlined,
            title: 'Verify safety number & security-code warnings',
            body: 'Each chat has a safety number you can compare with the other person through a '
                'trusted channel to confirm nobody is intercepting your conversation. The app also '
                'warns you automatically if a contact\'s encryption key changes unexpectedly.',
          ),
          const _FeatureEntry(
            icon: Icons.link_off_outlined,
            title: 'Phishing-link warnings',
            body: 'Links shared in a chat are checked against on-device heuristics for common '
                'phishing patterns, with a warning shown before you tap through.',
          ),
          const _FeatureEntry(
            icon: Icons.keyboard_alt_outlined,
            title: 'Private keyboard mode',
            body: 'Off by default. Turn it on in Settings > Privacy to ask your keyboard not to learn '
                'from or suggest what you type inside this app.',
          ),
          const _FeatureEntry(
            icon: Icons.web_asset_off_outlined,
            title: 'Hide app in recent apps',
            body: 'Hides your chats from the preview shown in your phone\'s recent-apps switcher — on '
                'by default.',
          ),
          const _FeatureEntry(
            icon: Icons.screenshot_outlined,
            title: 'Screenshot protection',
            body: 'Chats can\'t be screenshotted or screen-recorded — this is always on and isn\'t a '
                'setting you need to turn on.',
          ),
          const _FeatureEntry(
            icon: Icons.phonelink_lock_outlined,
            title: 'Require approval for new logins',
            body: 'Off by default. Turn it on in Account Security and a new sign-in has to be '
                'accepted from your already-signed-in device — as a live prompt if it\'s open, or a '
                'push notification if it isn\'t — with a number-matching step so you can\'t approve one '
                'by mistake.',
          ),
          const _FeatureEntry(
            icon: Icons.devices_other_outlined,
            title: 'One device at a time',
            body: 'Signing in somewhere new signs out anywhere else automatically, so you always '
                'know exactly where your account is active. Account Security shows your recent '
                'sign-in activity.',
          ),

          _SectionHeader('Chats & groups', scheme),
          const _FeatureEntry(
            icon: Icons.groups_outlined,
            title: 'Groups',
            body: 'Create a group from the chat list, add contacts directly, or invite anyone else '
                '(they need to accept first). Group admins can rename the group, set its description '
                'and photo, and turn on "Announcement-only" from group info.',
          ),
          const _FeatureEntry(
            icon: Icons.campaign_outlined,
            title: 'Announcement-only groups & the Announcements tab',
            body: 'Turn on "Announcement-only" and only admins can post — everyone else can still '
                'react, or long-press a post for "Reply privately" to message the sender 1:1. These '
                'groups live in their own Announcements tab at the bottom of the app, out of your way '
                'in Chats. Turn that tab off any time in Settings > Chats.',
          ),
          const _FeatureEntry(
            icon: Icons.groups_2_outlined,
            title: 'Communities',
            body: 'The Community tab at the bottom of the app is a public directory — anyone can '
                'start one, and every NWisp user can find and join one, unlike a group which is '
                'invisible to non-members. Give it an optional topic and location so people can '
                'filter for it, and messages still work exactly like any other chat: end-to-end '
                'encrypted, stored only on members\' own devices, never on a server.',
          ),
          const _FeatureEntry(
            icon: Icons.search_outlined,
            title: 'Search',
            body: 'A global search across every chat, plus per-chat search, calendar/date-range '
                'search, and a dedicated media/link/voice browser for any conversation.',
          ),
          const _FeatureEntry(
            icon: Icons.push_pin_outlined,
            title: 'Pin, mute, archive, and folders',
            body: 'Long-press any chat for quick Pin/Mute/Archive options, swipe left to archive or '
                'right to mute with a custom duration, or organize chats into your own folders — a '
                'chat can be in more than one.',
          ),
          const _FeatureEntry(
            icon: Icons.mark_chat_unread_outlined,
            title: 'Mark as unread & jump to unread',
            body: 'Flag any read chat as unread as a personal reminder (this never touches real read '
                'receipts), and jump straight to the first unread message in a long conversation.',
          ),
          const _FeatureEntry(
            icon: Icons.star_outline,
            title: 'Starred messages',
            body: 'Star any message to save it to a personal list, kept only on your device, separate '
                'from pinning a message inside a chat.',
          ),
          const _FeatureEntry(
            icon: Icons.edit_note_outlined,
            title: 'Edit & delete messages',
            body: 'Edit your own text message for a short window after sending (shown as '
                '"(edited)"), or delete it for just you or for everyone.',
          ),
          const _FeatureEntry(
            icon: Icons.schedule_send_outlined,
            title: 'Send later & silent send',
            body: 'Schedule a message to send at a chosen time, or send one silently so it doesn\'t '
                'trigger a notification for the recipient.',
          ),
          const _FeatureEntry(
            icon: Icons.sticky_note_2_outlined,
            title: 'Note to self',
            body: 'A private chat with only you in it, for reminders, drafts, or anything you want to '
                'save without sending it to anyone.',
          ),
          const _FeatureEntry(
            icon: Icons.notifications_off_outlined,
            title: 'Keyword mute',
            body: 'Mute notifications for messages containing specific words, per chat or group.',
          ),
          const _FeatureEntry(
            icon: Icons.visibility_off_outlined,
            title: 'Hide a chat',
            body: 'Hide any chat behind your app PIN entirely — it disappears from your chat list '
                'until you unlock it again.',
          ),
          const _FeatureEntry(
            icon: Icons.auto_delete_outlined,
            title: 'Inactivity auto-wipe',
            body: 'Off by default. Automatically clears a chat\'s local history if it\'s gone untouched '
                'for a set number of months — app-wide, or overridden per chat.',
          ),

          _SectionHeader('Customization', scheme),
          const _FeatureEntry(
            icon: Icons.palette_outlined,
            title: 'Chat themes',
            body: 'Open any chat or group\'s settings > Chat theme to pick a bubble colour, a '
                'wallpaper, or a ready-made combination of both — a chat now has far more choices '
                'than the original 8 wallpapers. Purely cosmetic and only visible on your own device.',
          ),
          const _FeatureEntry(
            icon: Icons.account_circle_outlined,
            title: 'Profile photo',
            body: 'Add a photo with the same crop/rotate/draw editor chats use, or remove it entirely '
                'from Edit profile — your photo is visible to everyone you\'re in a chat, group, or '
                'community with.',
          ),
          const _FeatureEntry(
            icon: Icons.app_registration_outlined,
            title: 'App icon badge',
            body: 'Shows your total unread count on the app icon — can be turned off in Settings for '
                'extra privacy.',
          ),

          _SectionHeader('Account', scheme),
          const _FeatureEntry(
            icon: Icons.pause_circle_outline,
            title: 'Temporarily deactivate',
            body: 'Hide your account and step away without deleting anything — from Account '
                'settings. Nobody can find or message you while deactivated; log back in any time to '
                'reactivate.',
          ),
          const _FeatureEntry(
            icon: Icons.download_outlined,
            title: 'Export your data',
            body: 'Download a copy of your profile and account settings as a file, any time, from '
                'Account settings.',
          ),
          const _FeatureEntry(
            icon: Icons.delete_forever_outlined,
            title: 'Delete your account',
            body: 'Permanently and irreversibly, from Account settings, with a type-to-confirm step. '
                'Removes your account, your local messages, and everything tied to it.',
          ),
          const _FeatureEntry(
            icon: Icons.shield_outlined,
            title: 'Reporting and appeals',
            body: 'Report a specific rule from Community Guidelines, with optional details and a '
                'photo — including reporting a Community itself, not just a member. Every report is '
                'reviewed by a real person; if an account is suspended, it sees the exact reason and '
                'can submit an appeal.',
          ),
          const _FeatureEntry(
            icon: Icons.block_outlined,
            title: 'Blocking',
            body: 'Block anyone from their chat settings — they can no longer message you, and you '
                'won\'t see messages from them either. Unblock any time from Blocked users in '
                'Settings.',
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme scheme;
  const _SectionHeader(this.title, this.scheme);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
      child: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: scheme.primary, letterSpacing: 0.4),
      ),
    );
  }
}

class _FeatureEntry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _FeatureEntry({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
