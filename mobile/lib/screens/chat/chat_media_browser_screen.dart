import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/local_message.dart';
import '../../services/link_safety_service.dart';
import '../../services/local_message_store.dart';
import '../../widgets/media_viewer_screen.dart';
import '../../widgets/message_link_text.dart';

/// Feature: link/media/file browser per chat — used by BOTH 1:1
/// (chat_settings_screen.dart) and group chats (group_info_screen.dart),
/// parameterized just by [conversationId] and a [title] to show. Three
/// tabs, matching what this app actually has message types for — no
/// "Files" tab, because there's no generic document/file attachment
/// anywhere in this app to browse (same honesty as the earlier "doesn't
/// apply" calls for features this app has no underlying support for):
///   - Media: photos and videos, as a scrollable grid. View-once media
///     is excluded — it's designed to disappear after one viewing, so it
///     has no place in a persistent browsable list.
///   - Voice: voice messages, as a simple list.
///   - Links: any URL found inside a text message, reusing the exact
///     same tap-to-open-with-a-warning flow as an inline chat bubble
///     (see widgets/message_link_text.dart) — opening a link from here
///     gets the same real-domain-and-heuristic-warning treatment as
///     opening one directly in the conversation.
class ChatMediaBrowserScreen extends StatefulWidget {
  final String conversationId;
  final String title;
  const ChatMediaBrowserScreen({super.key, required this.conversationId, required this.title});

  @override
  State<ChatMediaBrowserScreen> createState() => _ChatMediaBrowserScreenState();
}

class _ChatMediaBrowserScreenState extends State<ChatMediaBrowserScreen> {
  List<LocalMessage> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    LocalMessageStore.loadConversationForBrowsing(widget.conversationId).then((list) {
      if (mounted) setState(() {
        _messages = list;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = _messages.where((m) => m.mediaPath != null && !m.isViewOnce && (m.messageType == 'image' || m.messageType == 'video')).toList().reversed.toList();
    final voice = _messages.where((m) => m.mediaPath != null && m.messageType == 'voice').toList().reversed.toList();
    final linkMessages = _messages.where((m) => m.messageType == 'text' && LinkSafetyService.urlPattern.hasMatch(m.text)).toList().reversed.toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Media (${media.length})'),
              Tab(text: 'Voice (${voice.length})'),
              Tab(text: 'Links (${linkMessages.length})'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  media.isEmpty
                      ? Center(child: Text('No photos or videos yet', style: TextStyle(color: scheme.onSurfaceVariant)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(4),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
                          itemCount: media.length,
                          itemBuilder: (context, i) {
                            final m = media[i];
                            return InkWell(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => MediaViewerScreen(
                                    items: media.map((mm) => MediaViewerItem(path: mm.mediaPath!, isVideo: mm.messageType == 'video')).toList(),
                                    initialIndex: i,
                                  ),
                                ),
                              ),
                              child: m.messageType == 'video'
                                  ? Container(color: Colors.black87, child: const Icon(Icons.play_circle_fill, color: Colors.white))
                                  : Image.file(File(m.mediaPath!), fit: BoxFit.cover),
                            );
                          },
                        ),
                  voice.isEmpty
                      ? Center(child: Text('No voice messages yet', style: TextStyle(color: scheme.onSurfaceVariant)))
                      : ListView.separated(
                          itemCount: voice.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final m = voice[i];
                            return ListTile(
                              leading: const Icon(Icons.mic_outlined),
                              title: Text(_formatDate(m.createdAt)),
                              subtitle: Text(m.isMine ? 'You' : 'Them'),
                            );
                          },
                        ),
                  linkMessages.isEmpty
                      ? Center(child: Text('No links shared yet', style: TextStyle(color: scheme.onSurfaceVariant)))
                      : ListView.separated(
                          itemCount: linkMessages.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final m = linkMessages[i];
                            final urls = LinkSafetyService.urlPattern.allMatches(m.text).map((match) => match.group(0)!).toList();
                            return ListTile(
                              leading: const Icon(Icons.link),
                              title: Text(urls.first, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(_formatDate(m.createdAt)),
                              onTap: () => openMessageLink(context, urls.first),
                            );
                          },
                        ),
                ],
              ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    return '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
