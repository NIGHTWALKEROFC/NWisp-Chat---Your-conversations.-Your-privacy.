import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../services/secret_chat_service.dart';
import '../../widgets/user_avatar.dart';

const _green = Color(0xFF2ECC71);
const _bg = Color(0xFF07130E);
const _panel = Color(0xFF0F2119);

/// The rules shown before every secret chat, to the person starting it and
/// to the person being invited. Returns true if they tapped "I understand".
Future<bool> showSecretChatWarning(BuildContext context, {required String peerName, required bool initiating}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: _panel,
      title: Row(
        children: const [
          Icon(Icons.lock_rounded, color: _green),
          SizedBox(width: 10),
          Expanded(child: Text('Secret chat', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        ],
      ),
      content: SingleChildScrollView(
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white70, height: 1.35, fontSize: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(initiating
                  ? 'You are about to start a secret chat with $peerName. They must have NWisp open right now and accept.'
                  : '$peerName wants to start a secret chat with you.'),
              const SizedBox(height: 12),
              const _Rule(Icons.timer_outlined, 'Both of you must be online together. If either person leaves, the chat ends.'),
              const _Rule(Icons.delete_sweep_outlined, 'Nothing is saved. When someone leaves, every message is deleted and the other person is shown as offline.'),
              const _Rule(Icons.visibility_off_outlined, "It doesn't appear in your chat list, notifications or backups."),
              const _Rule(Icons.block_flipped, 'No forwarding, copying, calls, media or links. Screenshots are blocked.'),
              const _Rule(Icons.key_rounded, 'Fresh keys for every chat (classical + post-quantum). Compare the key code with them to be sure no one is in the middle.'),
              const SizedBox(height: 8),
              const Text(
                'Nothing can stop the other person from photographing their screen with another device.',
                style: TextStyle(color: Colors.amberAccent, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(initiating ? 'I understand — start' : 'I understand — accept'),
        ),
      ],
    ),
  );
  return ok == true;
}

class _Rule extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Rule(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: _green),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

/// Warning → send the request → open the waiting/chat screen.
Future<void> startSecretChatWith(BuildContext context, {required String peerUid, required String peerName}) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  if (!await showSecretChatWarning(context, peerName: peerName, initiating: true)) return;
  try {
    final profile = await AuthService().currentUserProfile();
    final myName = (profile.data()?['username'] as String?) ?? 'Someone';
    final session = await SecretChatService.instance.startAsInitiator(peerUid: peerUid, peerName: peerName, myName: myName);
    nav.push(MaterialPageRoute(builder: (_) => SecretChatScreen(session: session)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e is StateError ? e.message.toString() : "Couldn't start a secret chat.")));
  }
}

/// Shown when someone invites you (see HomeShell).
class SecretInviteScreen extends StatelessWidget {
  final SecretInvite invite;
  const SecretInviteScreen({super.key, required this.invite});

  Future<void> _accept(BuildContext context) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await showSecretChatWarning(context, peerName: invite.initiatorName, initiating: false)) return;
    try {
      final s = await SecretChatService.instance.acceptInvite(invite);
      nav.pushReplacement(MaterialPageRoute(builder: (_) => SecretChatScreen(session: s)));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't start the secret chat.")));
      nav.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              UserAvatar(uid: invite.initiatorUid, name: invite.initiatorName, radius: 56),
              const SizedBox(height: 20),
              Text(invite.initiatorName, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, color: _green, size: 18),
                  SizedBox(width: 6),
                  Text('wants to start a secret chat', style: TextStyle(color: Colors.white70, fontSize: 16)),
                ],
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final nav = Navigator.of(context);
                          await SecretChatService.instance.declineInvite(invite);
                          nav.maybePop();
                        },
                        child: const Text('Decline'),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.black),
                        onPressed: () => _accept(context),
                        child: const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class SecretChatScreen extends StatefulWidget {
  final SecretChatSession session;
  const SecretChatScreen({super.key, required this.session});

  @override
  State<SecretChatScreen> createState() => _SecretChatScreenState();
}

class _SecretChatScreenState extends State<SecretChatScreen> with WidgetsBindingObserver {
  SecretChatSession get s => widget.session;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  DateTime? _pausedAt;
  bool _covered = false;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenshotGuardService.acquire();
    s.addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (s.messages.length != _lastCount) {
      _lastCount = s.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _pausedAt ??= DateTime.now();
      setState(() => _covered = true);
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      setState(() => _covered = false);
      // Away for more than 20 seconds: the other side already sees you as
      // offline, so end it properly.
      if (at != null && DateTime.now().difference(at) > const Duration(seconds: 20)) {
        s.leave().then((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    s.removeListener(_onChange);
    s.dispose_();
    ScreenshotGuardService.release();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    if (s.phase == SecretPhase.declined ||
        s.phase == SecretPhase.timedOut ||
        s.phase == SecretPhase.failed ||
        s.phase == SecretPhase.closed) {
      return true;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Leave secret chat?', style: TextStyle(color: Colors.white)),
        content: Text(
          s.phase == SecretPhase.active
              ? 'Every message will be deleted and ${s.peerName} will see that you went offline. This can\'t be undone.'
              : 'Every message will be deleted from this phone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave & delete'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _pickTimer() async {
    const options = <(String, int)>[('Off', 0), ('5 seconds', 5), ('30 seconds', 30), ('1 minute', 60), ('5 minutes', 300), ('1 hour', 3600)];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _panel,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Self-destruct messages', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.$1, style: const TextStyle(color: Colors.white)),
                trailing: s.timerSeconds == o.$2 ? const Icon(Icons.check, color: _green) : null,
                onTap: () => Navigator.pop(ctx, o.$2),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await s.setTimer(picked);
  }

  void _showKey() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Encryption key', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(s.fingerprint.isEmpty ? '—' : s.fingerprint,
                style: const TextStyle(color: _green, fontSize: 24, fontFamily: 'monospace', letterSpacing: 2, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(
              'Ask ${s.peerName} to read out their code (by voice or in person). If it matches yours, no one is listening in.',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _send() async {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    await s.send(t);
  }

  String _timerLabel() {
    final t = s.timerSeconds;
    if (t == 0) return 'Off';
    if (t < 60) return '${t}s';
    if (t < 3600) return '${t ~/ 60}m';
    return '${t ~/ 3600}h';
  }

  @override
  Widget build(BuildContext context) {
    final active = s.phase == SecretPhase.active;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) {
          await s.leave();
          nav.pop();
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _panel,
          foregroundColor: Colors.white,
          titleSpacing: 0,
          title: Row(
            children: [
              UserAvatar(uid: s.peerUid, name: s.peerName, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.lock_rounded, size: 14, color: _green),
                      const SizedBox(width: 4),
                      Flexible(child: Text(s.peerName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
                    ]),
                    Text(
                      active ? 'secret chat · online' : (s.phase == SecretPhase.peerLeft ? 'offline' : 'secret chat'),
                      style: TextStyle(fontSize: 12, color: active ? _green : Colors.white54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (active || s.phase == SecretPhase.peerLeft)
              IconButton(
                tooltip: 'Self-destruct timer',
                onPressed: active ? _pickTimer : null,
                icon: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.timer_outlined),
                  if (s.timerSeconds > 0) Padding(padding: const EdgeInsets.only(left: 2), child: Text(_timerLabel(), style: const TextStyle(fontSize: 11))),
                ]),
              ),
            if (s.fingerprint.isNotEmpty) IconButton(tooltip: 'Encryption key', onPressed: _showKey, icon: const Icon(Icons.vpn_key_outlined)),
            PopupMenuButton<String>(
              color: _panel,
              onSelected: (v) async {
                final nav = Navigator.of(context);
                if (v == 'end' && await _confirmLeave()) {
                  await s.leave();
                  nav.pop();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'end', child: Text('End secret chat', style: TextStyle(color: Colors.redAccent))),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(child: _body()),
                _inputBar(active),
              ],
            ),
            if (_covered)
              Positioned.fill(
                child: Container(color: _bg, child: const Center(child: Icon(Icons.lock_rounded, size: 64, color: _green))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (s.phase) {
      case SecretPhase.waiting:
        return _center(Icons.hourglass_top_rounded, 'Waiting for ${s.peerName}…',
            'They need to have NWisp open and tap Accept. This request expires in 1 minute.', spinner: true);
      case SecretPhase.declined:
        return _center(Icons.block_flipped, '${s.peerName} declined', 'No secret chat was started.');
      case SecretPhase.timedOut:
        return _center(Icons.timer_off_outlined, 'No response', '${s.peerName} didn\'t accept in time. Secret chats only work when both people are online.');
      case SecretPhase.failed:
        return _center(Icons.error_outline, 'Secret chat closed', s.failMessage);
      case SecretPhase.closed:
        return _center(Icons.lock_rounded, 'Chat ended', 'All messages were deleted.');
      case SecretPhase.active:
      case SecretPhase.peerLeft:
        return Column(
          children: [
            if (s.phase == SecretPhase.peerLeft)
              Container(
                width: double.infinity,
                color: Colors.red.withValues(alpha: 0.18),
                padding: const EdgeInsets.all(10),
                child: Text('${s.peerName} went offline. This secret chat has ended — messaging is disabled. Leave to delete everything.',
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            Expanded(
              child: s.messages.isEmpty
                  ? _center(Icons.lock_rounded, 'Secret chat with ${s.peerName}',
                      'Messages exist only while you are both here. Tap the key icon to compare the encryption key.')
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: s.messages.length,
                      itemBuilder: (_, i) => _bubble(s.messages[s.messages.length - 1 - i]),
                    ),
            ),
          ],
        );
    }
  }

  Widget _center(IconData icon, String title, String body, {bool spinner = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: _green),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, height: 1.35)),
              if (spinner) ...[const SizedBox(height: 22), const CircularProgressIndicator(color: _green)],
            ],
          ),
        ),
      );

  Widget _bubble(SecretMessage m) {
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: m.mine ? const Color(0xFF1B6B43) : _panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Plain text on purpose: not selectable, links are not tappable.
            Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 15.5)),
            if (m.expiresAt != null)
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: Icon(Icons.timer_outlined, size: 11, color: Colors.white54),
              ),
          ],
        ),
      ),
    );
  }

  Widget _inputBar(bool active) {
    if (!active) {
      return const SizedBox(height: 0);
    }
    return SafeArea(
      top: false,
      child: Container(
        color: _panel,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                enableInteractiveSelection: true,
                contextMenuBuilder: (context, editableTextState) => const SizedBox.shrink(),
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.newline,
                inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                decoration: InputDecoration(
                  hintText: 'Secret message',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: _bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.black),
              onPressed: _send,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
