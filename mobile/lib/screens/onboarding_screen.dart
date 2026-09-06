import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class _OnboardingSlide {
  final IconData icon;
  final String title;
  final String body;
  const _OnboardingSlide({required this.icon, required this.title, required this.body});
}

const _slides = [
  _OnboardingSlide(
    icon: Icons.lock_outline_rounded,
    title: 'Private by default',
    body: 'Every chat is end-to-end encrypted — messages, photos, videos, and voice notes are '
        'only ever readable on your device and the person you sent them to. Nothing in between '
        'can read your conversations.',
  ),
  _OnboardingSlide(
    icon: Icons.timer_outlined,
    title: 'Disappearing messages',
    body: 'Set a per-chat timer and messages delete themselves automatically after the time you '
        'choose — or turn it off to keep everything, your call, per conversation.',
  ),
  _OnboardingSlide(
    icon: Icons.groups_outlined,
    title: 'Groups, the same way',
    body: 'Group chats get the same end-to-end encryption, per-member read receipts, and media '
        'sharing as one-on-one chats.',
  ),
  _OnboardingSlide(
    icon: Icons.phonelink_lock_outlined,
    title: 'You control your sessions',
    body: 'Only one device can be signed in at a time, and you can turn on "Require approval for '
        'new logins" in Account Security so a new sign-in needs your OK first.',
  ),
  _OnboardingSlide(
    icon: Icons.manage_accounts_outlined,
    title: 'Your account, your rules',
    body: 'Temporarily deactivate whenever you like, export your data, or delete your account '
        'entirely — all from Account settings, no waiting on support.',
  ),
  _OnboardingSlide(
    icon: Icons.shield_outlined,
    title: 'A safer space for everyone',
    body: 'Report anything that breaks the Community Guidelines with specific details and proof — '
        'every report is reviewed by a real person.',
  ),
];

/// Shown once, ever, per install — see SettingsService.getHasSeenOnboarding.
/// Wired in main.dart, right after AuthGate would otherwise show the chat
/// list or login screen for the very first time.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  Future<void> _finish() async {
    await SettingsService.setHasSeenOnboarding(true);
    widget.onDone();
  }

  void _next() {
    if (_index == _slides.length - 1) {
      _finish();
      return;
    }
    _controller.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: TextButton(onPressed: _finish, child: const Text('Skip')),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final slide = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(slide.icon, size: 84, color: scheme.primary),
                        const SizedBox(height: 32),
                        Text(
                          slide.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          slide.body,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4, fontSize: 15),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _slides.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _index ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _index ? scheme.primary : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(_index == _slides.length - 1 ? 'Get started' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
