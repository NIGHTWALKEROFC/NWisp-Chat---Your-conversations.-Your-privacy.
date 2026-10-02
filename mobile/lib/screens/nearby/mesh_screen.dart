import 'package:flutter/material.dart';
import '../../services/mesh_service.dart';
import '../../services/nearby_service.dart';
import '../../services/screenshot_guard_service.dart';

/// The "Mesh network" card on the Nearby tab: switch relaying on, see how many
/// phones are linked, open the public room, and message anyone on the mesh.
class MeshSection extends StatefulWidget {
  const MeshSection({super.key});

  @override
  State<MeshSection> createState() => _MeshSectionState();
}

class _MeshSectionState extends State<MeshSection> {
  final _nearby = NearbyService.instance;
  final _mesh = MeshService.instance;

  @override
  void initState() {
    super.initState();
    _nearby.addListener(_changed);
    _mesh.addListener(_changed);
  }

  @override
  void dispose() {
    _nearby.removeListener(_changed);
    _mesh.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.hub_outlined),
          title: const Text('Turn on mesh relay?'),
          content: const Text(
            'Your phone will link to other NWisp phones nearby automatically and pass their messages along, so people out of '
            'direct range can still reach each other.\n\n'
            '• The public room can be read by anyone on the mesh.\n'
            '• Direct messages are end-to-end encrypted — phones in between can\'t read them.\n'
            '• Nothing is saved, and it uses more battery while scanning.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _nearby.setMesh(on);
    if (on && !_nearby.scanning) await _nearby.start();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = _nearby.meshEnabled;
    final links = _nearby.meshLinks.length;
    final nodes = _mesh.nodeList;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.hub_outlined, color: scheme.primary),
            title: const Text('Mesh relay', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(on
                ? (links == 0 ? 'On — looking for other mesh phones…' : 'On — linked to $links phone${links == 1 ? '' : 's'} · ${nodes.length} reachable')
                : 'Pass messages along so people further away can reach each other'),
            value: on,
            onChanged: _toggle,
          ),
          if (on) ...[
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MeshRoomScreen())),
              icon: Badge(isLabelVisible: _mesh.roomUnread > 0, label: Text('${_mesh.roomUnread}'), child: const Icon(Icons.forum_outlined)),
              label: const Text('Public room'),
            ),
            if (nodes.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('On the mesh', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final n in nodes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: scheme.primary.withValues(alpha: 0.16),
                    child: Text(n.name.isEmpty ? '?' : n.name[0].toUpperCase(), style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800)),
                  ),
                  title: Row(children: [
                    Flexible(child: Text(n.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                    if (n.verified) ...[const SizedBox(width: 4), Icon(Icons.verified_rounded, size: 15, color: scheme.primary)],
                  ]),
                  subtitle: Text(n.hops <= 1 ? 'direct' : '${n.hops} hops away'),
                  trailing: (_mesh.unread[n.uid] ?? 0) > 0
                      ? CircleAvatar(radius: 11, backgroundColor: scheme.primary, child: Text('${_mesh.unread[n.uid]}', style: TextStyle(fontSize: 12, color: scheme.onPrimary)))
                      : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MeshDmScreen(uid: n.uid))),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The public room of the mesh. Anyone on the mesh can read it.
class MeshRoomScreen extends StatefulWidget {
  const MeshRoomScreen({super.key});

  @override
  State<MeshRoomScreen> createState() => _MeshRoomScreenState();
}

class _MeshRoomScreenState extends State<MeshRoomScreen> {
  final _mesh = MeshService.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _count = 0;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    _mesh.markRoomRead();
    _mesh.addListener(_changed);
  }

  @override
  void dispose() {
    _mesh.removeListener(_changed);
    ScreenshotGuardService.release();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _mesh.markRoomRead();
    setState(() {});
    if (_mesh.room.length != _count) {
      _count = _mesh.room.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _send() async {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    await _mesh.sendPublic(t);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final msgs = _mesh.room;
    return Scaffold(
      appBar: AppBar(title: const Text('Mesh public room')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              'Everyone on the mesh can read this room — don\'t share anything private. Not saved. Press and hold a message to mute that person.',
              style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
            ),
          ),
          Expanded(
            child: msgs.isEmpty
                ? Center(child: Text('Nothing yet.\nSay hello to everyone nearby 👋', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)))
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[msgs.length - 1 - i];
                      return Align(
                        alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: m.mine
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text('Mute ${m.fromName}?'),
                                      content: const Text('Their messages disappear for now and you won\'t see new ones until the mesh is switched off and on again.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mute')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) _mesh.mute(m.fromUid);
                                },
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                            decoration: BoxDecoration(
                              color: m.mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!m.mine)
                                  Row(mainAxisSize: MainAxisSize.min, children: [
                                    Text(m.fromName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: scheme.primary)),
                                    if (m.verified) ...[const SizedBox(width: 3), Icon(Icons.verified_rounded, size: 13, color: scheme.primary)],
                                    const SizedBox(width: 6),
                                    Text(m.hops == 0 ? 'direct' : '${m.hops + 1} hops', style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                                  ]),
                                Text(m.text, style: const TextStyle(fontSize: 15.5)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 500,
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                    decoration: InputDecoration(
                      hintText: 'Message everyone on the mesh',
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(onPressed: _send, icon: const Icon(Icons.send_rounded)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// An end-to-end encrypted direct message to someone on the mesh.
class MeshDmScreen extends StatefulWidget {
  final String uid;
  const MeshDmScreen({super.key, required this.uid});

  @override
  State<MeshDmScreen> createState() => _MeshDmScreenState();
}

class _MeshDmScreenState extends State<MeshDmScreen> {
  final _mesh = MeshService.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _count = 0;

  @override
  void initState() {
    super.initState();
    ScreenshotGuardService.acquire();
    _mesh.markRead(widget.uid);
    _mesh.addListener(_changed);
  }

  @override
  void dispose() {
    _mesh.removeListener(_changed);
    ScreenshotGuardService.release();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _mesh.markRead(widget.uid);
    setState(() {});
    final n = _mesh.threads[widget.uid]?.length ?? 0;
    if (n != _count) {
      _count = n;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _send() async {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    final err = await _mesh.sendDm(widget.uid, t);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final node = _mesh.nodes[widget.uid];
    final msgs = _mesh.threads[widget.uid] ?? const <MeshMessage>[];
    final name = node?.name ?? (msgs.isNotEmpty ? msgs.last.fromName : 'Mesh user');
    final gone = node == null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
            if (node?.verified == true) ...[const SizedBox(width: 4), Icon(Icons.verified_rounded, size: 16, color: scheme.primary)],
          ]),
          Text(gone ? 'out of reach' : (node.hops <= 1 ? 'direct' : '${node.hops} hops away'),
              style: TextStyle(fontSize: 12, color: gone ? scheme.error : scheme.onSurfaceVariant)),
        ]),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: scheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              'End-to-end encrypted through the mesh — phones in between can\'t read it. Not saved. Messages can take a few seconds when they hop through several phones.',
              style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
            ),
          ),
          Expanded(
            child: msgs.isEmpty
                ? Center(child: Text('Say hello to $name 👋', style: TextStyle(color: scheme.onSurfaceVariant)))
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
                          decoration: BoxDecoration(color: m.mine ? scheme.primaryContainer : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
                          child: Text(m.text, style: const TextStyle(fontSize: 15.5)),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: gone
                ? Padding(padding: const EdgeInsets.all(14), child: Text('This person is out of reach right now.', style: TextStyle(color: scheme.onSurfaceVariant)))
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 1000,
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
                    ]),
                  ),
          ),
        ],
      ),
    );
  }
}
