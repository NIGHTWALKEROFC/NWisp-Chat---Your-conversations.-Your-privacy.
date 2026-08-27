import 'package:flutter/material.dart';
import '../../models/local_message.dart';
import '../../services/local_message_store.dart';

/// In-chat search — given messages already live fully decrypted on this
/// device (see LocalMessageStore's own class comment), this is just an
/// in-memory substring filter over what's already stored locally. No
/// network round trip, no server-side index, nothing new to keep in sync.
///
/// Pops with the matched message's id when the person taps a result, so
/// the caller (ChatDetailScreen/GroupChatScreen) can scroll straight to
/// it using the same _jumpToMessage/_bubbleKeyFor machinery already used
/// for jumping to a reply's source message.
class ChatSearchScreen extends StatefulWidget {
  final String conversationId;
  final String peerUsername;

  const ChatSearchScreen({super.key, required this.conversationId, required this.peerUsername});

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final _controller = TextEditingController();
  List<LocalMessage> _results = [];
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _searched = false;
      });
      return;
    }
    final results = await LocalMessageStore.searchConversation(widget.conversationId, query);
    if (!mounted) return;
    setState(() {
      // Most recent match first — someone searching is usually looking
      // for something they remember more recently, not scrolling from the
      // very start of the chat's history.
      _results = results.reversed.toList();
      _searched = true;
    });
  }

  String _snippet(String text, String query) {
    final lower = text.toLowerCase();
    final idx = lower.indexOf(query.toLowerCase());
    if (idx < 0) return text;
    const window = 40;
    final start = (idx - window).clamp(0, text.length);
    final end = (idx + query.length + window).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _runSearch,
          decoration: InputDecoration(
            hintText: 'Search in chat with ${widget.peerUsername}',
            border: InputBorder.none,
          ),
          style: TextStyle(color: scheme.onSurface),
        ),
      ),
      body: !_searched
          ? Center(
              child: Text('Type to search this chat\'s messages', style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          : _results.isEmpty
              ? Center(child: Text('No matches', style: TextStyle(color: scheme.onSurfaceVariant)))
              : ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = _results[i];
                    return ListTile(
                      leading: Icon(m.isMine ? Icons.arrow_upward : Icons.arrow_downward, size: 18),
                      title: Text(_snippet(m.text, _controller.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_formatDate(m.createdAt)),
                      onTap: () => Navigator.pop(context, m.id),
                    );
                  },
                ),
    );
  }

  String _formatDate(DateTime d) {
    return '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
