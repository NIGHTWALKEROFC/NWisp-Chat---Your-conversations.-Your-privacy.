import 'dart:convert';
import 'package:flutter/material.dart';

/// The small "BOT" label shown next to a bot's name everywhere in the app,
/// like Telegram's "bot" identifier.
class BotBadge extends StatelessWidget {
  const BotBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
      child: Text('BOT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: scheme.primary, letterSpacing: 0.5)),
    );
  }
}

/// A bot's picture (a small embedded image) or, if it has none, a robot icon.
class BotAvatar extends StatelessWidget {
  final String? photoData;
  final String name;
  final double radius;
  const BotAvatar({super.key, required this.photoData, required this.name, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = photoData;
    if (data != null && data.contains(',')) {
      try {
        final bytes = base64Decode(data.substring(data.indexOf(',') + 1));
        return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes));
      } catch (_) {}
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primary.withValues(alpha: 0.18),
      child: Icon(Icons.smart_toy_rounded, color: scheme.primary, size: radius * 1.05),
    );
  }
}
