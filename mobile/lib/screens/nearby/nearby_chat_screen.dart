import 'package:flutter/material.dart';
import '../../services/nearby_service.dart';
import '../../services/screenshot_guard_service.dart';

/// A temporary chat with someone nearby. Nothing here is saved: the messages
/// live in memory and disappear when the connection ends.
class NearbyChatScreen extends StatefulWidget {
  final String endpointId;
  const NearbyChatScreen({super.key, required this.endpointId});

  @override
  State<NearbyChatScreen> createState() => _NearbyChatScreenState();
}

class _NearbyChatScreenState extends State<NearbyChatScreen> {
  final _service = NearbyService.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    _service.addListener(_changed);
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    ScreenshotGuardService.release();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  NearbyPeer? get _peer => _service.peers[widget.endpointId];

  void _changed() {
    if (!mounted) return;
    final p = _peer;
    if (p == null) {
      // The other person left or went out of range.
      setState(() {});
      return;
    }
    _service.markRead(p);
    setState(() {});
    if (p.messages.length != _lastCount) {
      _lastCount = p.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _send() async {
    final p = _peer;
    if (p == null) return;
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    await _service.sendText(p, t);
  }

  Future<void> _leave() async {
    final p = _peer;
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this chat?'),
        content: const Text('The connection closes and everything said here is gone for both of you.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End chat')),
        ],
      ),
    );
    if (ok != true) return;
    if (p != null) await _service.disconnect(p);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _peer;
    final name = p?.claimedName ?? 'Nearby';
    final gone = p == null || p.state != PeerState.connected;
    final waitingProof = p != null && !gone && p.verified == null;
    final blocked = p != null && _service.mode == NearbyMode.friends && p.verified != true;
    final msgs = p?.messages ?? const <NearbyMessage>[];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: scheme.primary.withValues(alpha: 0.16),
              child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
                    if (p?.verified == true) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.verified_rounded, size: 16, color: scheme.primary),
                    ],
                  ]),
                  Text(
                    gone ? 'disconnected' : (waitingProof ? 'checking identity…' : (p.verified == true ? 'verified · nearby' : 'unverified · nearby')),
                    style: TextStyle(fontSize: 12, color: gone ? scheme.error : scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [IconButton(tooltip: 'End chat', icon: const Icon(Icons.link_off_rounded), onPressed: gone ? () => Navigator.of(context).pop() : _leave)],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.timer_off_outlined, size: 18, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p?.verified == false
                        ? "Not saved anywhere. This person's identity couldn't be confirmed — they may not be who their name says."
                        : 'Not saved anywhere. Works without internet and disappears when the connection ends.',
                    style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
          if (gone)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.all(10),
              child: Text('$name is no longer connected (out of range or left). Messages can\'t be sent.',
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
            ),
          Expanded(
            child: msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('Say hello to $name 👋\nYou are chatting directly, phone to phone.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[msgs.length - 1 - i];
                      return Align(
                        alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                          decoration: BoxDecoration(
                            color: m.mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(m.text, style: TextStyle(color: m.mine ? scheme.onPrimaryContainer : scheme.onSurface, fontSize: 15.5)),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: (gone || blocked)
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(gone ? 'Chat ended' : 'Waiting to confirm who this is…', style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 2000,
                            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                            enableSuggestions: false,
                            autocorrect: false,
                            enableIMEPersonalizedLearning: false,
                            decoration: InputDecoration(
                              hintText: 'Message',
                              filled: true,
                              fillColor: scheme.surfaceContainerHigh,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(onPressed: _send, icon: const Icon(Icons.send_rounded)),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
