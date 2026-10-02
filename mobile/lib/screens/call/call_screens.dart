import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/call_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/group_call_service.dart';
import '../../services/screenshot_guard_service.dart';
import '../../widgets/user_avatar.dart';

String _mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

/// Full-screen ringing screen for an incoming voice call.
class IncomingCallScreen extends StatelessWidget {
  final IncomingCall call;
  const IncomingCallScreen({super.key, required this.call});

  Future<void> _accept(BuildContext context) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await CallService.instance.acceptCall(call);
      nav.pushReplacement(MaterialPageRoute(builder: (_) => VoiceCallScreen(session: session)));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't answer — check microphone permission.")));
      await CallService.instance.declineCall(call);
      nav.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1024),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              UserAvatar(uid: call.callerUid, name: call.callerName, radius: 62),
              const SizedBox(height: 22),
              Text(call.callerName,
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('NWisp voice call…', style: TextStyle(color: Colors.white70, fontSize: 16)),
              const SizedBox(height: 6),
              const Text('End-to-end encrypted', style: TextStyle(color: Colors.white38, fontSize: 12)),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundButton(
                      icon: Icons.call_end_rounded,
                      color: Colors.redAccent,
                      label: 'Decline',
                      onTap: () async {
                        final nav = Navigator.of(context);
                        await CallService.instance.declineCall(call);
                        nav.maybePop();
                      },
                    ),
                    _RoundButton(
                      icon: Icons.call_rounded,
                      color: Colors.green,
                      label: 'Answer',
                      onTap: () => _accept(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 56),
            ],
          ),
        ),
      ),
    );
  }
}

/// The in-call screen (both sides).
class VoiceCallScreen extends StatefulWidget {
  final VoiceCallSession session;
  const VoiceCallScreen({super.key, required this.session});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  VoiceCallSession get s => widget.session;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    s.phase.addListener(_onPhase);
  }

  void _onPhase() {
    if (s.phase.value == CallPhase.ended && !_leaving && mounted) {
      _leaving = true;
      final reason = s.endReason;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).maybePop();
        // Feature: "call me back" — when nobody picked up, offer to leave a
        // short note in the chat. Shown on the screen we go back to.
        const unanswered = {'No answer', 'Call declined', 'Busy on another call'};
        if (s.isCaller && unanswered.contains(reason) && s.conversationId.isNotEmpty) {
          messenger?.showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text('$reason. Want to ask ${s.peerName} to call you back?'),
            action: SnackBarAction(
              label: 'Ask to call back',
              onPressed: () {
                MessageRelayService.sendMessage(
                  conversationId: s.conversationId,
                  recipientUid: s.peerUid,
                  text: '📞 Please call me back',
                  ttlHours: 24,
                ).catchError((_) => '');
              },
            ),
          ));
        }
      });
    }
  }

  @override
  void dispose() {
    s.phase.removeListener(_onPhase);
    ScreenshotGuardService.release();
    super.dispose();
  }

  String _statusText(CallPhase p) {
    switch (p) {
      case CallPhase.calling:
        return 'Calling…';
      case CallPhase.ringing:
        return 'Ringing…';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.connected:
        return 'Connected';
      case CallPhase.ended:
        return s.endReason.isEmpty ? 'Call ended' : s.endReason;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) s.hangUp();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1024),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              UserAvatar(uid: s.peerUid, name: s.peerName, radius: 62),
              const SizedBox(height: 22),
              Text(s.peerName, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              ValueListenableBuilder<CallPhase>(
                valueListenable: s.phase,
                builder: (_, phase, __) => ValueListenableBuilder<int>(
                  valueListenable: s.seconds,
                  builder: (_, secs, __) => Text(
                    phase == CallPhase.connected ? _mmss(secs) : _statusText(phase),
                    style: const TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 13, color: Colors.white38),
                  SizedBox(width: 4),
                  Text('End-to-end encrypted voice call', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 14),
              _RecordingBanner(session: s),
              const Spacer(flex: 3),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: s.muted,
                    builder: (_, m, __) => _RoundButton(
                      icon: m ? Icons.mic_off_rounded : Icons.mic_rounded,
                      color: m ? Colors.white : Colors.white24,
                      iconColor: m ? Colors.black : Colors.white,
                      label: m ? 'Unmute' : 'Mute',
                      onTap: () => s.setMuted(!m),
                    ),
                  ),
                  _RoundButton(
                    icon: Icons.call_end_rounded,
                    color: Colors.redAccent,
                    label: 'End',
                    size: 72,
                    onTap: s.hangUp,
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: s.speaker,
                    builder: (_, on, __) => _RoundButton(
                      icon: on ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                      color: on ? Colors.white : Colors.white24,
                      iconColor: on ? Colors.black : Colors.white,
                      label: 'Speaker',
                      onTap: () => s.setSpeaker(!on),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 56),
            ],
          ),
        ),
      ),
    );
  }
}

/// "May be recording" notices on a 1:1 call (this phone and the other one).
class _RecordingBanner extends StatelessWidget {
  final VoiceCallSession session;
  const _RecordingBanner({required this.session});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: session.peerRecording,
      builder: (_, theirs, __) => ValueListenableBuilder<bool>(
        valueListenable: session.iRecording,
        builder: (_, mine, __) {
          if (!theirs && !mine) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _warningPill(theirs
                ? '${session.peerName}\'s phone may be recording this call.'
                : 'Another app on your phone is recording sound. ${session.peerName} was told.'),
          );
        },
      ),
    );
  }
}

Widget _warningPill(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.amber.shade700)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.fiber_manual_record, size: 14, color: Colors.redAccent),
        const SizedBox(width: 8),
        Flexible(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5))),
      ]),
    );

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String label;
  final double size;
  final VoidCallback onTap;
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: size, height: size, child: Icon(icon, color: iconColor, size: size * 0.44)),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}


// ============================================================ Group calls

/// Starts a group voice call — or joins the one already going on in this group.
Future<void> startOrJoinGroupCall(
  BuildContext context, {
  required String groupId,
  required String groupName,
  required List<String> memberUids,
}) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final existing = await GroupCallService.instance.ongoingIn(groupId);
    final GroupCallSession session;
    if (existing != null) {
      session = await GroupCallService.instance.join(existing);
    } else {
      if (memberUids.length > 40) {
        messenger.showSnackBar(const SnackBar(content: Text('Group calls work in groups of up to 40 people.')));
        return;
      }
      final profile = await AuthService().currentUserProfile();
      final myName = (profile.data()?['username'] as String?) ?? 'Someone';
      session = await GroupCallService.instance.start(
        groupId: groupId,
        groupName: groupName,
        memberUids: memberUids,
        myName: myName,
      );
    }
    nav.push(MaterialPageRoute(builder: (_) => GroupCallScreen(session: session)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text(e is StateError ? e.message.toString() : "Couldn't start the group call — check the microphone permission and your connection."),
    ));
  }
}

/// Full-screen ringing for a group call.
class GroupIncomingCallScreen extends StatelessWidget {
  final IncomingGroupCall call;
  const GroupIncomingCallScreen({super.key, required this.call});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1024),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              const CircleAvatar(radius: 56, backgroundColor: Color(0xFF1B2A6B), child: Icon(Icons.groups_rounded, size: 56, color: Colors.white)),
              const SizedBox(height: 22),
              Text(call.groupName, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('${call.starterName} started a group voice call', style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 6),
              const Text('End-to-end encrypted', style: TextStyle(color: Colors.white38, fontSize: 12)),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundButton(
                      icon: Icons.close_rounded,
                      color: Colors.redAccent,
                      label: 'Ignore',
                      onTap: () async {
                        final nav = Navigator.of(context);
                        await GroupCallService.instance.ignore(call);
                        nav.maybePop();
                      },
                    ),
                    _RoundButton(
                      icon: Icons.call_rounded,
                      color: Colors.green,
                      label: 'Join',
                      onTap: () async {
                        final nav = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final s = await GroupCallService.instance.join(call);
                          nav.pushReplacement(MaterialPageRoute(builder: (_) => GroupCallScreen(session: s)));
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text(e is StateError ? e.message.toString() : "Couldn't join the call.")));
                          nav.maybePop();
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 56),
            ],
          ),
        ),
      ),
    );
  }
}

class GroupCallScreen extends StatefulWidget {
  final GroupCallSession session;
  const GroupCallScreen({super.key, required this.session});

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  GroupCallSession get s => widget.session;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    s.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (s.ended && !_leaving) {
      _leaving = true;
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    s.removeListener(_changed);
    ScreenshotGuardService.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = s.participants.entries.toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) s.leave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1024),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(s.groupName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(s.ended ? s.endReason : _mmss(s.seconds), style: const TextStyle(color: Colors.white70, fontSize: 16)),
              const SizedBox(height: 4),
              Text('${entries.length + 1} in the call · up to ${GroupCallService.maxParticipants}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
              if (s.recordingUids.isNotEmpty || s.iRecording)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                  child: _warningPill(
                    s.iRecording && s.recordingUids.isEmpty
                        ? 'Another app on your phone is recording sound. The others were told.'
                        : '${s.recordingUids.map((u) => s.names[u] ?? 'Someone').join(', ')}${s.recordingUids.length == 1 ? '\'s phone' : ' — phones'} may be recording this call.',
                  ),
                ),
              const SizedBox(height: 18),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.05,
                  children: [
                    _tile(s.myUid, 'You', true, s.muted),
                    for (final e in entries) _tile(e.key, s.names[e.key] ?? '…', e.value, false),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundButton(
                    icon: s.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    color: s.muted ? Colors.white : Colors.white24,
                    iconColor: s.muted ? Colors.black : Colors.white,
                    label: s.muted ? 'Unmute' : 'Mute',
                    onTap: () => s.setMuted(!s.muted),
                  ),
                  _RoundButton(icon: Icons.call_end_rounded, color: Colors.redAccent, label: 'Leave', size: 72, onTap: s.leave),
                  _RoundButton(
                    icon: s.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                    color: s.speaker ? Colors.white : Colors.white24,
                    iconColor: s.speaker ? Colors.black : Colors.white,
                    label: 'Speaker',
                    onTap: () => s.setSpeaker(!s.speaker),
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(String uid, String name, bool connected, bool muted) {
    return Container(
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(uid: uid, name: name, radius: 34),
              if (muted)
                const Positioned(
                  right: -4,
                  bottom: -4,
                  child: CircleAvatar(radius: 11, backgroundColor: Colors.white, child: Icon(Icons.mic_off, size: 14, color: Colors.black)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(connected ? 'Connected' : 'Connecting…',
              style: TextStyle(color: connected ? const Color(0xFF6EE7A8) : Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
