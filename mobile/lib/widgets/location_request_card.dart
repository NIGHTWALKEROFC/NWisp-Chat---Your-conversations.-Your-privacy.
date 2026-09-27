import 'package:flutter/material.dart';

/// Feature: "Request their location" — the companion to live location
/// sharing. Rendered for any message with messageType == 'location_request'
/// (see ChatDetailScreen's message-type switch). The request itself is an
/// ordinary end-to-end encrypted chat message with no coordinates in it;
/// tapping "Share my location" on the recipient's side opens the exact
/// same duration-picker sheet the "Live location" attachment option does.
class LocationRequestCard extends StatelessWidget {
  final bool isMine;
  final VoidCallback onShareLocation;

  const LocationRequestCard({super.key, required this.isMine, required this.onShareLocation});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(Icons.person_pin_circle_outlined, color: scheme.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isMine ? 'You asked for their live location' : 'Asked you to share your live location',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          if (!isMine)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: onShareLocation,
                  icon: const Icon(Icons.share_location, size: 16),
                  label: const Text('Share my location', style: TextStyle(fontSize: 12.5)),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8), minimumSize: const Size(0, 34)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
