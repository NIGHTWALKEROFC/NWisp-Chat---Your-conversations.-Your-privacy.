import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/screenshot_guard_service.dart';
import '../services/security_chat_lock_service.dart';
import '../services/security_chat_service.dart';
import '../widgets/nwisp_ui.dart';
import 'security_chat_lock_screens.dart';
import 'settings/account_security_screen.dart';
import 'settings/forgot_password_screen.dart';

/// The official "NWisp Chat" conversation — see SecurityChatService for what
/// it really is. Read-only: there is no message box, because there's nobody
/// on the other end.
///
/// Like every other chat in the app it's protected from screenshots while
/// open (these messages name your devices and locations).
class SecurityChatScreen extends StatefulWidget {
  const SecurityChatScreen({super.key});

  @override
  State<SecurityChatScreen> createState() => _SecurityChatScreenState();
}

class _SecurityChatScreenState extends State<SecurityChatScreen> with WidgetsBindingObserver {
  final _auth = AuthService();

  // Optional lock (see SecurityChatLockService). The chat starts locked
  // whenever the lock is on and locks itself again if the app goes to the
  // background, the same way the app lock does.
  bool _checking = true;
  bool _lockEnabled = false;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    WidgetsBinding.instance.addObserver(this);
    _checkLock();
  }

  Future<void> _checkLock() async {
    final service = SecurityChatLockService.instance;
    final enabled = await service.isEnabled();
    await service.load();
    if (!mounted) return;
    setState(() {
      _lockEnabled = enabled;
      _unlocked = !enabled;
      _checking = false;
    });
    if (!enabled) {
      SecurityChatService.instance.markRead();
      _offerLockOnce();
    }
  }

  /// The very first time this chat is opened, ask once whether to protect it.
  /// "Not now" is fine — it's never asked again, and the lock stays available
  /// from the lock button here and from Settings > Security.
  Future<void> _offerLockOnce() async {
    final service = SecurityChatLockService.instance;
    if (await service.hasBeenOffered()) return;
    await service.markOffered();
    if (!mounted) return;
    final turnedOn = await showSecurityChatLockOffer(context);
    if (!mounted) return;
    if (turnedOn) {
      // They just set it up themselves, so don't lock them out of this visit.
      setState(() => _lockEnabled = true);
    }
  }

  void _onUnlocked() {
    setState(() => _unlocked = true);
    SecurityChatService.instance.markRead();
  }

  Future<void> _openLockSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityChatLockSettingsScreen()));
    final enabled = await SecurityChatLockService.instance.isEnabled();
    if (!mounted) return;
    // Whoever is here has already passed the gate (or there was none), so
    // changing the setting doesn't lock this visit.
    setState(() {
      _lockEnabled = enabled;
      if (!enabled) _unlocked = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _lockEnabled && _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenshotGuardService.release();
    // Anything that arrived while this screen was open counts as seen too —
    // but not if it was never unlocked.
    if (_unlocked) SecurityChatService.instance.markRead();
    super.dispose();
  }

  String _clock(DateTime? t) {
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}, ${t.year}';
  }

  Widget _titleRow(ColorScheme scheme) {
    return Row(
      children: [
        const NwispOfficialAvatar(radius: 19),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Text(
                      'NWisp Chat Notifications',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const VerifiedBadge(size: 16),
                ],
              ),
              Text(
                'Account alerts · read only',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final uid = _auth.currentUserId;

    if (_checking) {
      return Scaffold(
        appBar: AppBar(titleSpacing: 0, title: _titleRow(scheme)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_lockEnabled && !_unlocked) {
      return Scaffold(
        appBar: AppBar(titleSpacing: 0, title: _titleRow(scheme)),
        body: SecurityChatUnlockGate(onUnlocked: _onUnlocked),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _titleRow(scheme),
        actions: [
          IconButton(
            tooltip: 'Chat lock',
            icon: Icon(_lockEnabled ? Icons.lock_rounded : Icons.lock_open_rounded),
            onPressed: _openLockSettings,
          ),
        ],
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : Column(
              children: [
                Expanded(
                  child: StreamBuilder<List<SecurityNotice>>(
                    stream: SecurityChatService.instance.notices(uid),
                    builder: (context, snap) {
                      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                      final notices = snap.data!;
                      // Newest at the bottom, like any chat: the list is
                      // reversed, so index 0 (bottom) is the newest notice
                      // and the very last item is the welcome message.
                      return ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                        itemCount: notices.length + 1,
                        itemBuilder: (context, i) {
                          if (i == notices.length) return _welcome(scheme);
                          final n = notices[i];
                          // Show a date chip above the first notice of each day.
                          final olderIsSameDay = i + 1 < notices.length &&
                              n.time != null &&
                              notices[i + 1].time != null &&
                              _sameDay(n.time!, notices[i + 1].time!);
                          final showDay = n.time != null && !olderIsSameDay;
                          return Column(
                            children: [
                              if (showDay) _dayChip(scheme, _dayLabel(n.time!)),
                              _bubble(context, scheme, n),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                // No message box — replaced by a plain note, so it's obvious
                // this isn't a conversation you can type into.
                Container(
                  width: double.infinity,
                  color: scheme.surfaceContainerLow,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: SafeArea(
                    top: false,
                    child: Text(
                      'You can\'t reply to this chat',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _dayChip(ColorScheme scheme, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
    );
  }

  Widget _welcome(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          child: NwispCard(
            radius: 18,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('NWisp Chat Notifications', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 6),
                Text(
                  "Official NWisp alerts for your account appear here — a new sign-in, a password change, or "
                  'two-step verification being switched on or off. Nobody can send messages to this chat, '
                  'and you can\'t reply to it.',
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4, fontSize: 13.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, ColorScheme scheme, SecurityNotice n) {
    final tint = n.needsAttention ? scheme.error : scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: tint.withValues(alpha: 0.16), shape: BoxShape.circle),
                      child: Icon(n.icon, size: 17, color: tint),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(n.body, style: const TextStyle(height: 1.4, fontSize: 14)),
                if (n.needsAttention) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Review activity'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AccountSecurityScreen()),
                        ),
                      ),
                      ActionChip(
                        label: const Text('Change password'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ForgotPasswordScreen(knownEmail: _auth.currentUser?.email),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(_clock(n.time), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
