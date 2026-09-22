import 'package:flutter/material.dart';
import '../../services/community_service.dart';

/// Round picture for a community: its photo, or a "groups" icon.
class CommunityAvatar extends StatelessWidget {
  final String? url;
  final double radius;
  const CommunityAvatar({super.key, required this.url, this.radius = 26});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final has = url != null && url!.isNotEmpty;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundImage: has ? NetworkImage(url!) : null,
      onForegroundImageError: has ? (_, __) {} : null,
      child: Icon(Icons.groups_rounded, size: radius * 0.9, color: scheme.onPrimaryContainer),
    );
  }
}

/// The small facts under a community's name: topic, place, size, and whether
/// only admins can post.
class CommunityFacts extends StatelessWidget {
  final CommunityListing listing;
  const CommunityFacts({super.key, required this.listing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(IconData icon, String text, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color ?? scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (listing.category != null) chip(Icons.label_outline, listing.category!),
        if (!listing.location.isEmpty) chip(Icons.place_outlined, listing.location.label),
        chip(
          Icons.people_outline,
          listing.isFull ? 'Full · ${listing.memberCount}/${listing.maxMembers}' : '${listing.memberCount}/${listing.maxMembers} members',
        ),
        if (listing.onlyAdminsCanSend) chip(Icons.campaign_outlined, 'Announcements only'),
      ],
    );
  }
}
