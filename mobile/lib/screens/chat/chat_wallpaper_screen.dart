import 'package:flutter/material.dart';
import '../../services/chat_wallpaper_service.dart';

/// Feature: chat wallpapers/themes per conversation. Shared by both 1:1
/// and group chats — a simple grid of presets, tap to apply immediately
/// (no separate "save" step, matching how the theme picker elsewhere in
/// this app already works).
class ChatWallpaperScreen extends StatefulWidget {
  final String conversationId;
  const ChatWallpaperScreen({super.key, required this.conversationId});

  @override
  State<ChatWallpaperScreen> createState() => _ChatWallpaperScreenState();
}

class _ChatWallpaperScreenState extends State<ChatWallpaperScreen> {
  String _selectedId = 'default';

  @override
  void initState() {
    super.initState();
    ChatWallpaperService.getWallpaper(widget.conversationId).then((w) {
      if (mounted) setState(() => _selectedId = w.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat wallpaper')),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.8),
        itemCount: kChatWallpapers.length,
        itemBuilder: (context, i) {
          final w = kChatWallpapers[i];
          final selected = w.id == _selectedId;
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              await ChatWallpaperService.setWallpaper(widget.conversationId, w.id);
              if (mounted) setState(() => _selectedId = w.id);
            },
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: w.colors.isEmpty ? scheme.surfaceContainerHighest : (w.colors.length == 1 ? w.colors.first : null),
                      gradient: w.colors.length > 1 ? LinearGradient(colors: w.colors, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                      borderRadius: BorderRadius.circular(12),
                      border: selected ? Border.all(color: scheme.primary, width: 3) : Border.all(color: scheme.outlineVariant),
                    ),
                    child: selected ? Icon(Icons.check_circle, color: w.colors.isEmpty ? scheme.primary : Colors.white) : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(w.name, style: const TextStyle(fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );
  }
}
