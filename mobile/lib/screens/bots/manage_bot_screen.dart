import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import 'bot_chat_screen.dart';
import 'bot_commands_screen.dart';
import 'bot_token_screen.dart';

/// Manage one of my bots: edit its name / description / picture, switch its
/// rules, get a new API key, or delete it.
class ManageBotScreen extends StatefulWidget {
  final BotInfo bot;
  const ManageBotScreen({super.key, required this.bot});

  @override
  State<ManageBotScreen> createState() => _ManageBotScreenState();
}

class _ManageBotScreenState extends State<ManageBotScreen> {
  late BotInfo _bot = widget.bot;
  late final _name = TextEditingController(text: _bot.name);
  late final _desc = TextEditingController(text: _bot.description);
  late final Map<String, bool> _rules = {for (final r in BotService.rules) r.key: _bot.rule(r.key)};
  bool _saving = false;
  bool _infoDirty = false;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveInfo() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('A bot needs a name.');
      return;
    }
    setState(() => _saving = true);
    try {
      final b = await BotService.instance.updateBot(_bot.username, name: name, description: _desc.text.trim());
      if (!mounted) return;
      setState(() {
        _bot = b;
        _infoDirty = false;
      });
      _snack('Saved');
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256, imageQuality: 70);
    if (x == null) return;
    final data = 'data:image/jpeg;base64,${base64Encode(await x.readAsBytes())}';
    try {
      final b = await BotService.instance.updateBot(_bot.username, photoData: data);
      if (mounted) setState(() => _bot = b);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _removePhoto() async {
    try {
      final b = await BotService.instance.updateBot(_bot.username, photoData: null);
      if (mounted) setState(() => _bot = b);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _toggleRule(String key, bool value) async {
    final before = _rules[key] ?? false;
    setState(() => _rules[key] = value);
    try {
      final b = await BotService.instance.updateBot(_bot.username, rules: _rules);
      if (mounted) setState(() => _bot = b);
    } catch (e) {
      if (mounted) setState(() => _rules[key] = before);
      _snack(e.toString());
    }
  }

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.vpn_key_rounded),
        title: const Text('Generate a new API key?'),
        content: const Text('The current key stops working immediately. Your running bot will be signed out until you paste in the new key.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Generate new key')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final token = await BotService.instance.regenerateToken(_bot.username);
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => BotTokenScreen(username: _bot.username, token: token, isNew: false)));
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _delete() async {
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          icon: Icon(Icons.delete_forever_rounded, color: Theme.of(ctx).colorScheme.error),
          title: const Text('Delete this bot?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('@${_bot.username} and every chat people had with it will be deleted for good, and its username becomes free again.'),
              const SizedBox(height: 12),
              TextField(
                controller: confirm,
                onChanged: (_) => setD(() {}),
                decoration: InputDecoration(labelText: 'Type @${_bot.username} to confirm', border: const OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: confirm.text.trim().replaceFirst('@', '').toLowerCase() == _bot.username ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    confirm.dispose();
    if (ok != true) return;
    try {
      await BotService.instance.deleteBot(_bot.username);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _snack(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Manage bot')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_bot.status != 'active')
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.gpp_maybe_outlined, color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This bot is ${_bot.status}. ${_bot.statusReason ?? ''}\nIt can\'t send or receive messages and doesn\'t show up for other people.',
                    style: TextStyle(color: scheme.onErrorContainer, height: 1.35),
                  ),
                ),
              ]),
            ),
          Center(child: BotAvatar(photoData: _bot.photoData, name: _bot.name, radius: 46)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(onPressed: _setPhoto, icon: const Icon(Icons.photo_camera_outlined, size: 18), label: const Text('Change picture')),
              if (_bot.photoData != null) TextButton(onPressed: _removePhoto, child: const Text('Remove')),
            ],
          ),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('@${_bot.username}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(width: 8),
                const BotBadge(),
              ],
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _name,
            maxLength: 64,
            onChanged: (_) => setState(() => _infoDirty = true),
            decoration: const InputDecoration(labelText: 'Bot name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _desc,
            maxLength: 300,
            maxLines: 3,
            onChanged: (_) => setState(() => _infoDirty = true),
            decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
          ),
          FilledButton(
            onPressed: (_infoDirty && !_saving) ? _saveInfo : null,
            child: _saving ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save changes'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotChatScreen(username: _bot.username))),
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text('Open chat with my bot'),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.terminal),
            title: const Text('Command menu', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(_bot.commands.isEmpty ? 'No commands yet' : _bot.commands.map((c) => '/${c.command}').take(4).join('  ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => BotCommandsScreen(bot: _bot)));
              if (changed == true) {
                final mine = await BotService.instance.listMine();
                final fresh = mine.where((b) => b.username == _bot.username);
                if (fresh.isNotEmpty && mounted) setState(() => _bot = fresh.first);
              }
            },
          ),
          const SizedBox(height: 14),
          const Row(children: [Icon(Icons.tune_rounded, size: 20), SizedBox(width: 8), Text('Bot rules', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 4),
          const Text('Changes apply straight away.', style: TextStyle(fontSize: 12.5)),
          for (final r in BotService.rules)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(r.icon),
              title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(r.subtitle, style: const TextStyle(fontSize: 12.5)),
              value: _rules[r.key] ?? false,
              onChanged: (v) => _toggleRule(r.key, v),
            ),
          const SizedBox(height: 14),
          const Text('API key', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          const Text(
            "For safety the key can't be shown again after creation. If you lost it or think it leaked, generate a new one.",
            style: TextStyle(fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _regenerate, icon: const Icon(Icons.vpn_key_rounded), label: const Text('Generate new API key')),
          if (_bot.webhook)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('A webhook is currently set for this bot.', style: TextStyle(fontSize: 12.5)),
            ),
          const SizedBox(height: 26),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error, side: BorderSide(color: scheme.error)),
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete bot'),
          ),
        ],
      ),
    );
  }
}
