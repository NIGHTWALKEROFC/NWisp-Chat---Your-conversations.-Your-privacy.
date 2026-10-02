import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/bot_service.dart';

/// Shows a bot's API key (right after creating the bot, or after generating a
/// new one). The key is never stored on the server in readable form, so this
/// is the only time it can be copied — losing it means generating a new one.
class BotTokenScreen extends StatefulWidget {
  final String username;
  final String token;
  final bool isNew;
  const BotTokenScreen({super.key, required this.username, required this.token, this.isNew = true});

  @override
  State<BotTokenScreen> createState() => _BotTokenScreenState();
}

class _BotTokenScreenState extends State<BotTokenScreen> {
  bool _revealed = false;

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
    // Don't leave a secret sitting on the clipboard.
    Timer(const Duration(minutes: 1), () => Clipboard.setData(const ClipboardData(text: '')));
  }

  String get _example => '''import requests

TOKEN = "PASTE_YOUR_API_KEY_HERE"   # keep this secret
API = "${BotService.apiBase}/bot" + TOKEN

offset = 0
while True:
    r = requests.get(API + "/getUpdates", params={"offset": offset, "timeout": 20}).json()
    for u in r.get("result", []):
        offset = u["update_id"] + 1
        m = u.get("message")
        if m:
            requests.post(API + "/sendMessage", json={
                "chat_id": m["chat"]["id"],
                "text": "You said: " + m["text"],
            })
''';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final masked = '${widget.token.split(':').first}:${'•' * 24}';
    return Scaffold(
      appBar: AppBar(title: Text(widget.isNew ? 'Your bot is ready' : 'New API key')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('@${widget.username}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Do not share this API key with anyone. Whoever has it can control your bot and read every message people send to it. '
                    'It is shown only now — NWisp keeps just a fingerprint of it. If it leaks or you lose it, generate a new one (the old one stops working at once).',
                    style: TextStyle(color: scheme.onErrorContainer, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('API key', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: SelectableText(_revealed ? widget.token : masked, style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(_revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  label: Text(_revealed ? 'Hide' : 'Show'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _copy(widget.token, 'API key'),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy key'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Text('Where your bot talks to NWisp', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: SelectableText('${BotService.apiBase}/bot<API_KEY>/<method>', style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copy('${BotService.apiBase}/bot', 'Address'),
            icon: const Icon(Icons.link),
            label: const Text('Copy address (without key)'),
          ),
          const SizedBox(height: 22),
          const Text('Hosting', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            "NWisp doesn't run your bot. You write it and host it wherever you like — your own computer, a phone, a server or any hosting service. "
            'It only needs to call the address above. Methods work like Telegram bots: getMe, getUpdates, sendMessage, sendPhoto, editMessageText, '
            'deleteMessage, sendChatAction, setWebhook, setMyCommands and more.\n\n'
            'Messages with bots are not end-to-end encrypted: your bot (and you, as its owner) can read them.',
            style: TextStyle(height: 1.4),
          ),
          const SizedBox(height: 14),
          const Text('Starter example (Python)', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: SelectableText(_example, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copy(_example, 'Example'),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy example'),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      ),
    );
  }
}
