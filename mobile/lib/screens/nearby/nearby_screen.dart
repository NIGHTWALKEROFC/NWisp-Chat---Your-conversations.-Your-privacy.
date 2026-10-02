import 'package:flutter/material.dart';
import '../../services/nearby_service.dart';
import 'mesh_screen.dart';
import 'nearby_chat_screen.dart';

/// The "Nearby" tab: find people close by (Bluetooth + Wi-Fi, no internet),
/// ask to connect, and chat temporarily. Scanning is OFF until switched on.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  final _service = NearbyService.instance;
  bool _promptOpen = false;

  @override
  void initState() {
    super.initState();
    _service.load().then((_) {
      if (mounted) setState(() {});
    });
    _service.addListener(_changed);
    _service.incomingRequest.addListener(_onRequest);
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    _service.incomingRequest.removeListener(_onRequest);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _onRequest() async {
    final p = _service.incomingRequest.value;
    if (p == null || _promptOpen || !mounted) return;
    _promptOpen = true;
    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.bluetooth_connected_rounded),
        title: const Text('Chat request'),
        content: Text(
          '${p.claimedName} (nearby) wants to chat with you. It is a temporary chat — nothing is saved.'
          '${p.isFriend ? '' : '\n\nThey are not in your contacts, so their name can\'t be trusted yet.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Decline')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Accept')),
        ],
      ),
    );
    _promptOpen = false;
    if (accept == true) {
      await _service.accept(p);
    } else {
      await _service.decline(p);
    }
  }

  Widget _stepRow(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Relay links of the mesh are not chats; they show in the Mesh card instead.
    final all = _service.peers.values.where((p) => !p.mesh).toList();
    final connected = all.where((p) => p.state == PeerState.connected).toList();
    final pending = all.where((p) => p.state == PeerState.requesting || p.state == PeerState.connecting || p.state == PeerState.incoming).toList();
    final found = all.where((p) => p.state == PeerState.found || p.state == PeerState.declined).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [scheme.primary.withValues(alpha: 0.18), scheme.tertiary.withValues(alpha: 0.12)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.wifi_tethering_rounded, color: scheme.primary),
                  const SizedBox(width: 10),
                  const Text('Chat without internet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                ]),
                const SizedBox(height: 8),
                const Text(
                  'Find NWisp users within roughly 100 metres using Bluetooth and Wi-Fi, and chat directly phone to phone. '
                  'These chats are temporary — they are not saved and never appear in your chat list.',
                  style: TextStyle(height: 1.35),
                ),
                const SizedBox(height: 10),
                _stepRow(Icons.bluetooth, 'Turn on Bluetooth'),
                _stepRow(Icons.wifi, 'Turn on Wi-Fi (no network needed)'),
                _stepRow(Icons.location_on_outlined, 'Turn on Location — Android needs it to find nearby phones. Nothing about your location is used or stored.'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Who can I find?', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          SegmentedButton<NearbyMode>(
            segments: const [
              ButtonSegment(value: NearbyMode.friends, icon: Icon(Icons.people_alt_outlined), label: Text('My contacts')),
              ButtonSegment(value: NearbyMode.everyone, icon: Icon(Icons.public), label: Text('Everyone')),
            ],
            selected: {_service.mode},
            onSelectionChanged: (s) => _service.setMode(s.first),
          ),
          const SizedBox(height: 6),
          Text(
            _service.mode == NearbyMode.friends
                ? 'Only people in your contacts are shown, and they are checked with their security key before you can chat.'
                : 'Any NWisp user nearby can appear. Send a request and chat once they accept. Names of people who are not your contacts can\'t be trusted.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.3),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _service.busy ? null : (_service.scanning ? () => _service.stop() : () => _service.start()),
            icon: _service.busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_service.scanning ? Icons.stop_circle_outlined : Icons.radar_rounded),
            label: Text(_service.scanning ? 'Stop scanning' : 'Start scanning'),
          ),
          if (_service.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                child: Text(_service.error!, style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
              ),
            ),
          const MeshSection(),
          if (_service.scanning)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Looking for people nearby…', style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
          if (connected.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Connected', style: TextStyle(fontWeight: FontWeight.w800)),
            for (final p in connected) _peerTile(p, scheme),
          ],
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Waiting', style: TextStyle(fontWeight: FontWeight.w800)),
            for (final p in pending) _peerTile(p, scheme),
          ],
          if (found.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('People nearby', style: TextStyle(fontWeight: FontWeight.w800)),
            for (final p in found) _peerTile(p, scheme),
          ],
          if (_service.scanning && all.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Center(
                child: Text(
                  _service.mode == NearbyMode.friends
                      ? 'None of your contacts are nearby yet.\nThey need to have Nearby scanning on too.'
                      : 'Nobody found yet.\nThey need to have Nearby scanning on too.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _peerTile(NearbyPeer p, ColorScheme scheme) {
    String subtitle;
    Widget? trailing;
    VoidCallback? onTap;
    switch (p.state) {
      case PeerState.found:
        subtitle = p.isFriend ? 'In your contacts' : 'NWisp user nearby · not a contact';
        trailing = FilledButton.tonal(onPressed: () => _service.request(p), child: const Text('Connect'));
        break;
      case PeerState.declined:
        subtitle = 'Declined your request';
        trailing = TextButton(onPressed: () => _service.request(p), child: const Text('Ask again'));
        break;
      case PeerState.requesting:
        subtitle = 'Waiting for them to accept…';
        trailing = const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2));
        break;
      case PeerState.connecting:
        subtitle = 'Connecting…';
        trailing = const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2));
        break;
      case PeerState.incoming:
        subtitle = 'Wants to chat';
        trailing = FilledButton(onPressed: () => _service.accept(p), child: const Text('Accept'));
        break;
      case PeerState.connected:
        subtitle = p.verified == true ? 'Verified contact' : (p.verified == false ? 'Unverified' : 'Checking identity…');
        trailing = p.unread > 0
            ? CircleAvatar(radius: 11, backgroundColor: scheme.primary, child: Text('${p.unread}', style: TextStyle(fontSize: 12, color: scheme.onPrimary)))
            : const Icon(Icons.chevron_right);
        onTap = () {
          _service.markRead(p);
          Navigator.push(context, MaterialPageRoute(builder: (_) => NearbyChatScreen(endpointId: p.endpointId)));
        };
        break;
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primary.withValues(alpha: 0.16),
        child: Text(p.claimedName.isEmpty ? '?' : p.claimedName[0].toUpperCase(), style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800)),
      ),
      title: Row(children: [
        Flexible(child: Text(p.claimedName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
        if (p.verified == true) ...[const SizedBox(width: 4), Icon(Icons.verified_rounded, size: 16, color: scheme.primary)],
      ]),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
