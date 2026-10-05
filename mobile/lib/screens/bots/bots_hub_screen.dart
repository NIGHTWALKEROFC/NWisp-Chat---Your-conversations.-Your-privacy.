import 'package:flutter/material.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import 'bot_admin_screen.dart';
import 'create_bot_screen.dart';
import 'manage_bot_screen.dart';

/// Settings → Bots: ONLY for managing the bots you made (edit, rules,
/// commands, token, delete). Chatting with a bot happens from the Chats
/// screen — bots you open show up there like any other chat, and you can
/// find a bot by typing its username into the search box on that screen.
class BotsHubScreen extends StatefulWidget {
  const BotsHubScreen({super.key});

  @override
  State<BotsHubScreen> createState() => _BotsHubScreenState();
}

class _BotsHubScreenState extends State<BotsHubScreen> {
  List<BotInfo>? _mine;
  String? _error;
  bool _admin = false;

  @override
  void initState() {
    super.initState();
    _load();
    BotService.instance.isAdmin().then((v) {
      if (mounted && v) setState(() => _admin = v);
    });
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await BotService.instance.listMine();
      if (!mounted) return;
      setState(() => _mine = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ]),
        ),
      );
    }
    final items = _mine;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text("You haven't made a bot yet.\nTap New bot to create one.", textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          for (final b in items)
            ListTile(
              leading: BotAvatar(photoData: b.photoData, name: b.name),
              title: Row(children: [
                Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                const SizedBox(width: 6),
                const BotBadge(),
              ]),
              subtitle: Text('@${b.username}${!b.rule('public') ? ' · private (testing)' : ''}'),
              trailing: const Icon(Icons.settings_outlined),
              onTap: () async {
                await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ManageBotScreen(bot: b)));
                if (mounted) _load();
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage bots'),
        actions: [
          if (_admin)
            IconButton(
              tooltip: 'Reported bots (admin)',
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BotAdminScreen())),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBotScreen()));
          _load();
        },
        icon: const Icon(Icons.add),
        label: const Text('New bot'),
      ),
      body: _body(),
    );
  }
}
