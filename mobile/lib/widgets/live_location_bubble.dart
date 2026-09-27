import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../services/live_location_service.dart';
import '../screens/chat/live_location_view_screen.dart';

/// Feature: live location sharing — the chat-bubble version, rendered for
/// any message with messageType == 'live_location' (see
/// ChatDetailScreen's message-type switch). [payloadText] is that
/// message's decrypted text: {"shareId": "...", "expiresAt": "..."}.
class LiveLocationBubble extends StatelessWidget {
  final String payloadText;
  final bool isMine;

  const LiveLocationBubble({super.key, required this.payloadText, required this.isMine});

  @override
  Widget build(BuildContext context) {
    late final String shareId;
    try {
      shareId = (jsonDecode(payloadText) as Map<String, dynamic>)['shareId'] as String;
    } catch (_) {
      // A malformed/old payload — fail safely rather than crash the whole
      // message list over one bad bubble.
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Live location (unavailable)'),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: LiveLocationService.watchShare(shareId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox(
            width: 220,
            height: 60,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final share = LiveShare.fromDoc(snapshot.data!.data()!);
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveLocationViewScreen(shareId: shareId))),
          child: SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: SizedBox(
                    height: 120,
                    child: (share.lat == null || share.lng == null)
                        ? Container(color: Colors.grey.shade300)
                        : IgnorePointer(
                            // A static preview — the full interactive map is
                            // the tap-through screen (LiveLocationViewScreen).
                            child: FlutterMap(
                              options: MapOptions(
                                initialCenter: ll.LatLng(share.lat!, share.lng!),
                                initialZoom: 15,
                                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'com.nwisp.chat',
                                ),
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: ll.LatLng(share.lat!, share.lng!),
                                      width: 32,
                                      height: 32,
                                      child: Icon(Icons.location_on, color: share.hasEnded ? Colors.grey : Colors.red, size: 32),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Icon(
                        share.hasEnded ? Icons.location_off_outlined : Icons.location_on,
                        size: 16,
                        color: share.hasEnded ? null : (share.isStale ? Colors.orange : Colors.green),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          share.hasEnded ? 'Live location ended' : (share.isStale ? 'May be out of date' : 'Live location'),
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isMine && !share.hasEnded && FirebaseAuth.instance.currentUser?.uid == share.senderUid)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                        onPressed: () async {
                          await LiveLocationService.stopActiveShare();
                        },
                        child: const Text('Stop sharing', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
