import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import 'bot_report.dart';

/// The shared "bot room" of one bot in one group. Every member of the group
/// sees the whole room. The bot itself only sees what its rules allow: with
/// "Read all group messages" OFF that is /commands, @mentions of the bot and
/// replies to the bot — everything else members type here stays between them.
/// (This room is not end-to-end encrypted, unlike the group's normal chat.)
class BotGroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final BotInfo bot;
  const BotGroupChatScreen({super.key, required this.groupId, required this.groupName, required this.bot});

  @override
  State<BotGroupChatScreen> createState() => _BotGroupChatScreenState();
}

class _BotGroupChatScreenState extends State<BotGroupChatScreen> {
  final _service = BotService.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final Map<int, BotMessage> _messages = {};
  final String _me = FirebaseAuth.instance.currentUser?.uid ?? '';
  bool _alive = true;
  bool _sending = false;
  String? _error;
  int _lastId = 0;
  String? _since;
  BotMessage? _replyTo;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _alive = false;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _merge(List<BotMessage> list) {
    for (final m in list) {
      final e = _messages[m.id];
      if (e != null) {
        e.body = m.body;
        e.extra = m.extra;
        e.edited = m.edited;
        e.deleted = m.deleted;
      } else {
        _messages[m.id] = m;
      }
      if (m.id > _lastId) _lastId = m.id;
    }
  }

  Future<void> _start() async {
    try {
      final r = await _service.groupPoll(widget.groupId, widget.bot.username, history: true);
      _since = r.serverTime;
      if (!mounted) return;
      setState(() => _merge(r.messages));
      _toBottom();
      _loop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loop() async {
    var failures = 0;
    while (_alive && mounted) {
      try {
        final r = await _service.groupPoll(widget.groupId, widget.bot.username, afterId: _lastId, since: _since, waitSeconds: 12);
        failures = 0;
        if (!_alive || !mounted) return;
        _since = r.serverTime;
        final before = _messages.length;
        setState(() => _merge(r.messages));
        if (_messages.length != before) _toBottom();
      } catch (_) {
        failures++;
        await Future<void>.delayed(Duration(seconds: failures > 3 ? 15 : 4));
      }
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });

  Future<void> _send([String? override]) async {
    final text = (override ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (override == null) _input.clear();
    final reply = _replyTo;
    setState(() {
      _sending = true;
      _replyTo = null;
    });
    try {
      final r = await _service.groupSend(widget.groupId, widget.bot.username, text, replyTo: reply?.id);
      if (!mounted) return;
      setState(() => _merge([
            BotMessage(
              id: r.id, fromBot: false, kind: 'text', body: text, userUid: _me,
              extra: {'seenByBot': r.seenByBot, if (reply != null) 'replyTo': reply.id},
              edited: false, deleted: false, createdAt: DateTime.now(),
            ),
          ]));
      _toBottom();
    } catch (e) {
      if (mounted) {
        if (override == null) _input.text = text;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String get _privacyLine => widget.bot.rule('seeAllMessages')
      ? '@${widget.bot.username} can read EVERY message in this room.'
      : '@${widget.bot.username} only sees /commands, @${widget.bot.username} mentions and replies to the bot.';

  Widget _bubble(BotMessage m) {
    final scheme = Theme.of(context).colorScheme;
    if (m.isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(m.body, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final mine = !m.fromBot && m.userUid == _me;
    final fromBot = m.fromBot;
    final photo = m.extra['photo'];
    final replyId = m.extra['replyTo'];
    final quoted = replyId is int ? _messages[replyId] : null;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: fromBot ? () => setState(() => _replyTo = m) : null,
        onDoubleTap: () => setState(() => _replyTo = m),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : (fromBot ? scheme.tertiaryContainer : scheme.surfaceContainerHigh),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mine)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(fromBot ? widget.bot.name : (m.senderName.isEmpty ? 'member' : m.senderName),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: scheme.primary)),
                  if (fromBot) ...[const SizedBox(width: 6), const BotBadge()],
                ]),
              if (quoted != null)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.primary, width: 3))),
                  child: Text(quoted.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              if (photo is String && photo.startsWith('https://'))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network(photo, width: 220, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined))),
                ),
              if (m.deleted)
                Text('Message deleted', style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))
              else if (m.body.isNotEmpty)
                SelectableText(m.body, style: const TextStyle(fontSize: 15.5)),
              if (mine && m.extra['seenByBot'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('seen by bot', style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _messages.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    final cmds = widget.bot.rule('commandsMenu') ? widget.bot.commands : const <BotCommand>[];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          BotAvatar(photoData: widget.bot.photoData, name: widget.bot.name, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(widget.bot.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
                const SizedBox(width: 6),
                const BotBadge(),
              ]),
              Text('in ${widget.groupName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'report') showReportBotDialog(context, widget.bot.username);
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'report', child: Text('Report bot'))],
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)))
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: scheme.secondaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    'Everyone in ${widget.groupName} can read this room, and it is not end-to-end encrypted. $_privacyLine',
                    style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('Nothing here yet.'))
                      : ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.all(12),
                          itemCount: list.length,
                          itemBuilder: (_, i) => _bubble(list[list.length - 1 - i]),
                        ),
                ),
                if (_replyTo != null)
                  Container(
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                    child: Row(children: [
                      Icon(Icons.reply, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Replying: ${_replyTo!.body}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                      IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyTo = null)),
                    ]),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                    child: Row(children: [
                      if (cmds.isNotEmpty)
                        IconButton(
                          tooltip: 'Commands',
                          icon: const Icon(Icons.terminal),
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            showDragHandle: true,
                            builder: (ctx) => SafeArea(
                              child: ListView(shrinkWrap: true, children: [
                                for (final c in cmds)
                                  ListTile(
                                    title: Text('/${c.command}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                    subtitle: c.description.isEmpty ? null : Text(c.description),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _send('/${c.command}');
                                    },
                                  ),
                              ]),
                            ),
                          ),
                        ),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 4000,
                          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                          decoration: InputDecoration(
                            hintText: 'Message the room',
                            filled: true,
                            fillColor: scheme.surfaceContainerHigh,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(onPressed: _sending ? null : () => _send(), icon: const Icon(Icons.send_rounded)),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }
}
