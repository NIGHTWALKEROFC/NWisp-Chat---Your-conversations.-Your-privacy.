import 'package:flutter/material.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import 'bot_chat_screen.dart';
import 'create_bot_screen.dart';
import 'manage_bot_screen.dart';

/// Bots: the ones I made (manage / edit / delete / new key) and the ones I
/// have chatted with. Also where to open any bot by its username.
class BotsHubScreen extends StatefulWidget {
  const BotsHubScreen({super.key});

  @override
  State<BotsHubScreen> createState() => _BotsHubScreenState();
}

class _BotsHubScreenState extends State<BotsHubScreen> {
  List<BotInfo>? _mine;
  List<BotInfo>? _chats;
  String? _error;
  final _open = TextEditingController();
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Future.wait([BotService.instance.listMine(), BotService.instance.myChats()]);
      if (!mounted) return;
      setState(() {
        _mine = r[0];
        _chats = r[1];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openByName() async {
    var u = _open.text.trim().toLowerCase().replaceFirst('@', '');
    if (u.isEmpty) return;
    if (!u.endsWith('_bot')) u = '${u}_bot';
    setState(() => _opening = true);
    try {
      final r = await BotService.instance.getBot(u);
      if (!mounted) return;
      if (r.bot == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.reason == 'private' ? '@$u exists but isn\'t open to everyone yet.' : 'No bot called @$u.'),
        ));
      } else {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => BotChatScreen(username: u)));
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _tile(BotInfo b, {required bool mine}) => ListTile(
        leading: BotAvatar(photoData: b.photoData, name: b.name),
        title: Row(children: [
          Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
          const SizedBox(width: 6),
          const BotBadge(),
        ]),
        subtitle: Text('@${b.username}${mine && !b.rule('public') ? ' · private (testing)' : ''}'),
        trailing: Icon(mine ? Icons.settings_outlined : Icons.chevron_right),
        onTap: () async {
          if (mine) {
            final deleted = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ManageBotScreen(bot: b)));
            if (deleted == true || mounted) _load();
          } else {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => BotChatScreen(username: b.username)));
            _load();
          }
        },
      );

  Widget _list(List<BotInfo>? items, {required bool mine}) {
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
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            mine ? "You haven't made a bot yet.\nTap New bot to create one." : "You haven't chatted with any bot yet.\nType a bot's username above to open it.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [for (final b in items) _tile(b, mine: mine)]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bots'),
          bottom: const TabBar(tabs: [Tab(text: 'My bots'), Tab(text: 'Chats')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateBotScreen()));
            _load();
          },
          icon: const Icon(Icons.add),
          label: const Text('New bot'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: TextField(
                controller: _open,
                autocorrect: false,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _openByName(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Open a bot, e.g. nwisp_bot',
                  border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  suffixIcon: _opening
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _openByName),
                ),
              ),
            ),
            Expanded(child: TabBarView(children: [_list(_mine, mine: true), _list(_chats, mine: false)])),
          ],
        ),
      ),
    );
  }
}
