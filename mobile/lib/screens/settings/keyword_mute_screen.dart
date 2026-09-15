import 'package:flutter/material.dart';
import '../../services/keyword_mute_service.dart';

/// Feature: mute by keyword. Shared editor for both the GLOBAL list
/// (Settings > Notifications, [conversationId] null) and a per-chat/
/// per-group list (Chat settings > "Muted keywords", [conversationId]
/// set) — same simple add/remove chip list either way.
class KeywordMuteScreen extends StatefulWidget {
  final String? conversationId;
  const KeywordMuteScreen({super.key, this.conversationId});

  @override
  State<KeywordMuteScreen> createState() => _KeywordMuteScreenState();
}

class _KeywordMuteScreenState extends State<KeywordMuteScreen> {
  List<String> _keywords = [];
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = widget.conversationId == null
        ? await KeywordMuteService.getGlobalKeywords()
        : await KeywordMuteService.getChatKeywords(widget.conversationId!);
    if (mounted) setState(() => _keywords = list);
  }

  Future<void> _save(List<String> list) async {
    if (widget.conversationId == null) {
      await KeywordMuteService.setGlobalKeywords(list);
    } else {
      await KeywordMuteService.setChatKeywords(widget.conversationId!, list);
    }
    if (mounted) setState(() => _keywords = list);
  }

  void _add() {
    final word = _controller.text.trim();
    if (word.isEmpty || _keywords.contains(word)) return;
    _save([..._keywords, word]);
    _controller.clear();
  }

  void _remove(String word) {
    _save(_keywords.where((k) => k != word).toList());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isGlobal = widget.conversationId == null;
    return Scaffold(
      appBar: AppBar(title: Text(isGlobal ? 'Muted keywords (all chats)' : 'Muted keywords for this chat')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isGlobal
                  ? 'A message containing any of these words never triggers a notification, in any chat or group — the message itself still arrives and shows normally when you open the chat, it just won\'t alert you.'
                  : 'Adds to (doesn\'t replace) your global muted keywords, but only for this one chat.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(hintText: 'Add a word or phrase', border: OutlineInputBorder()),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('Add')),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _keywords.isEmpty
                  ? Center(child: Text('No muted keywords yet', style: TextStyle(color: scheme.onSurfaceVariant)))
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _keywords
                          .map((k) => Chip(label: Text(k), onDeleted: () => _remove(k)))
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
