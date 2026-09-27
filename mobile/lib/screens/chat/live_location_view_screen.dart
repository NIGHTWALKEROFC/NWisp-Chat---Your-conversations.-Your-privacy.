import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../../services/live_location_service.dart';

/// Feature: live location sharing — full-screen map, opened by tapping the
/// in-chat bubble (see LiveLocationBubble). Uses OpenStreetMap tiles via
/// flutter_map — no API key/billing setup required, unlike Google Maps.
class LiveLocationViewScreen extends StatelessWidget {
  final String shareId;
  const LiveLocationViewScreen({super.key, required this.shareId});

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Live location')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: LiveLocationService.watchShare(shareId),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final share = LiveShare.fromDoc(snapshot.data!.data()!);
          if (share.lat == null || share.lng == null) {
            return const Center(child: Text('No location yet.'));
          }
          final point = ll.LatLng(share.lat!, share.lng!);
          final isMine = myUid == share.senderUid;

          return Stack(
            children: [
              FlutterMap(
                options: MapOptions(initialCenter: point, initialZoom: 16),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.nwisp.chat',
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.location_on,
                          size: 44,
                          color: share.hasEnded ? Colors.grey : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          share.hasEnded
                              ? 'Live location ended'
                              : share.isStale
                                  ? 'May be out of date'
                                  : 'Live · updates automatically',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: share.hasEnded ? null : (share.isStale ? Colors.orange : Colors.green),
                          ),
                        ),
                        if (!share.hasEnded)
                          Text('Sharing ends in ${_formatRemaining(share.remaining)}', style: const TextStyle(fontSize: 12.5)),
                        if (share.updatedAt != null)
                          Text('Last updated ${TimeOfDay.fromDateTime(share.updatedAt!).format(context)}', style: const TextStyle(fontSize: 12.5)),
                        if (isMine && !share.hasEnded) ...[
                          const SizedBox(height: 10),
                          FilledButton.tonal(
                            onPressed: () async {
                              await LiveLocationService.stopActiveShare();
                              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stopped sharing')));
                            },
                            child: const Text('Stop sharing'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _formatRemaining(Duration d) {
  if (d.isNegative) return 'less than a minute';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m';
}
