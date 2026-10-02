import 'package:flutter/material.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import 'bot_group_chat_screen.dart';

/// Bots in one group: see them, open each bot's room, and (admins only) add
/// or remove bots.
class GroupBotsScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  const GroupBotsScreen({super.key, required this.groupId, required this.groupName});

  @override
  State<GroupBotsScreen> createState() => _GroupBotsScreenState();
}

class _GroupBotsScreenState extends State<GroupBotsScreen> {
  List<BotInfo>? _bots;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final b = await BotService.instance.groupBots(widget.groupId);
      if (mounted) setState(() => _bots = b);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _add() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.smart_toy_outlined),
        title: const Text('Add a bot'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            autocorrect: false,
            decoration: const InputDecoration(prefixText: '@', hintText: 'nwisp_bot', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          const Text(
            'The bot gets a shared room in this group. It sees only what its rules allow, and the room is not end-to-end encrypted. Only admins can add bots.',
            style: TextStyle(fontSize: 12.5),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.isEmpty) return;
    var u = name.toLowerCase().replaceFirst('@', '');
    if (!u.endsWith('_bot')) u = '${u}_bot';
    try {
      await BotService.instance.groupAddBot(widget.groupId, u);
      _snack('Added @$u');
      _load();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _remove(BotInfo b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove @${b.username}?'),
        content: const Text('The bot leaves the group. Its room history stays for a few days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await BotService.instance.groupRemoveBot(widget.groupId, b.username);
      _load();
    } catch (e) {
      _snack(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Bots in ${widget.groupName}', overflow: TextOverflow.ellipsis)),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add bot')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : _bots == null
              ? const Center(child: CircularProgressIndicator())
              : _bots!.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No bots in this group yet.\nAn admin can add one with the button below.', textAlign: TextAlign.center)))
                  : ListView(children: [
                      for (final b in _bots!)
                        ListTile(
                          leading: BotAvatar(photoData: b.photoData, name: b.name),
                          title: Row(children: [Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))), const SizedBox(width: 6), const BotBadge()]),
                          subtitle: Text('@${b.username} · ${b.rule('seeAllMessages') ? 'reads all messages' : 'sees commands, mentions and replies'}'),
                          trailing: IconButton(icon: const Icon(Icons.close), tooltip: 'Remove', onPressed: () => _remove(b)),
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotGroupChatScreen(groupId: widget.groupId, groupName: widget.groupName, bot: b))),
                        ),
                    ]),
    );
  }
}
