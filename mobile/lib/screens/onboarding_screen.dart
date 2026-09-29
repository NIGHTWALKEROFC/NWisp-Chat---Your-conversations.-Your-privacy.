import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../widgets/nwisp_ui.dart';

/// Shown once, ever, per install — see SettingsService.getHasSeenOnboarding.
/// Wired in auth_gate.dart, right before AuthGate would otherwise show the
/// chat list or login screen for the very first time.
///
/// Redesigned 2026-09-29: three slides like the new design sheet
/// (Private Chats / Stories / Your Privacy). The feature rows on the last
/// slide only mention things the app really does.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 3;

  final _controller = PageController();
  int _index = 0;

  Future<void> _finish() async {
    await SettingsService.setHasSeenOnboarding(true);
    widget.onDone();
  }

  void _next() {
    if (_index == _pageCount - 1) {
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
    final last = _index == _pageCount - 1;
    return Scaffold(
      body: NwispBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _index = i),
                  children: const [
                    _SlideShell(
                      title: 'Private Chats',
                      body: 'Send messages, share media and stay connected — all with end-to-end encryption.',
                      child: _ShieldArt(),
                    ),
                    _SlideShell(
                      title: 'Stories',
                      body: 'Share your moments with close friends through stories. They disappear after 24 hours.',
                      child: _StoriesArt(),
                    ),
                    _SlideShell(
                      title: 'Your Privacy',
                      body: 'Your data. Your control. You\'re in charge.',
                      child: _PrivacyList(),
                    ),
                  ],
                ),
              ),
              if (!last)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _pageCount,
                    (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _index ? 20 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _index ? scheme.primary : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 8),
                child: GradientButton(label: last ? 'Get Started' : 'Next', onPressed: _next),
              ),
              SizedBox(
                height: 48,
                child: last
                    ? null
                    : TextButton(
                        onPressed: _finish,
                        child: Text('Skip', style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w500)),
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideShell extends StatelessWidget {
  final String title;
  final String body;
  final Widget child;
  const _SlideShell({required this.title, required this.body, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 40),
          Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 26)),
          const SizedBox(height: 12),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45, fontSize: 15),
          ),
          Expanded(child: Center(child: child)),
        ],
      ),
    );
  }
}

/// Glowing shield-with-padlock, with two soft orbit rings behind it.
class _ShieldArt extends StatelessWidget {
  const _ShieldArt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      height: 260,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (final t in [0.0, 0.5])
            Transform.rotate(
              angle: t * 1.2,
              child: Container(
                width: 250 - t * 40,
                height: 170 + t * 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(200),
                  border: Border.all(color: scheme.primary.withValues(alpha: 0.35), width: 1.4),
                ),
              ),
            ),
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [scheme.primary.withValues(alpha: 0.35), Colors.transparent]),
            ),
          ),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF38C8FF), Color(0xFF4C7DFF), Color(0xFF8A4DFF)],
            ).createShader(r),
            child: const Icon(Icons.shield_rounded, size: 150, color: Colors.white),
          ),
          const Icon(Icons.lock_rounded, size: 56, color: Colors.white),
        ],
      ),
    );
  }
}

/// A small illustrative mock of the Stories tab (avatar row + one story
/// card). It's artwork only — no real data.
class _StoriesArt extends StatelessWidget {
  const _StoriesArt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const names = ['My Story', 'Alex', 'Zara', 'Riya'];
    return NwispCard(
      radius: 22,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < names.length; i++)
                Column(
                  children: [
                    GradientRing(
                      padding: 2,
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primaryContainer,
                        child: Text(names[i][0], style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(names[i], style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 210,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2A2F7A), Color(0xFFB4548C), Color(0xFFF2A45B)],
              ),
            ),
            alignment: Alignment.bottomLeft,
            padding: const EdgeInsets.all(12),
            child: const Text('My Story · 2h ago', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _PrivacyList extends StatelessWidget {
  const _PrivacyList();

  @override
  Widget build(BuildContext context) {
    const rows = [
      (Icons.lock_outline_rounded, 'End-to-End Encryption', 'Even the server can\'t read your messages'),
      (Icons.timer_outlined, 'Disappearing Messages', 'Set a timer per chat'),
      (Icons.phone_disabled_outlined, 'No Call Features', 'Only chat & stories'),
      (Icons.phonelink_lock_outlined, 'You Control Your Sessions', 'Approve every new login'),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: NwispCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  _IconBadge(icon: r.$1),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                        const SizedBox(height: 2),
                        Text(
                          r.$3,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  const _IconBadge({required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: scheme.primary, size: 22),
    );
  }
}
