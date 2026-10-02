import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/bot_service.dart';
import '../../widgets/bot_badge.dart';
import '../../widgets/message_link_text.dart';
import 'bot_report.dart';

/// Chat with a bot. Bot chats are NOT end-to-end encrypted (the bot's program
/// has to read them) — a notice at the top says so. Messages live on the
/// server only for 7 days and are loaded by polling while this screen is open.
class BotChatScreen extends StatefulWidget {
  final String username;
  const BotChatScreen({super.key, required this.username});

  @override
  State<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends State<BotChatScreen> {
  final _service = BotService.instance;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final Map<int, BotMessage> _messages = {};
  BotInfo? _bot;
  String? _loadError;
  bool _alive = true;
  bool _typing = false;
  bool _showNotice = true;
  bool _sending = false;
  int _lastId = 0;
  String? _since;
  String _myName = '';

  @override
  void initState() {
    super.initState();
    _input.addListener(_inputChanged);
    _start();
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _alive = false;
    _input.removeListener(_inputChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final r = await _service.getBot(widget.username);
      if (r.bot == null) {
        setState(() => _loadError = r.reason == 'private'
            ? "This bot isn't open to everyone yet."
            : r.reason == 'suspended'
                ? 'This bot has been suspended.'
                : 'This bot no longer exists.');
        return;
      }
      _bot = r.bot;
      try {
        final p = await AuthService().currentUserProfile();
        _myName = (p.data()?['username'] as String?) ?? '';
      } catch (_) {}
      if (mounted) setState(() {});
      await _history();
      _loop();
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  void _merge(List<BotMessage> list) {
    for (final m in list) {
      final existing = _messages[m.id];
      if (existing != null) {
        existing.body = m.body;
        existing.extra = m.extra;
        existing.edited = m.edited;
        existing.deleted = m.deleted;
      } else {
        _messages[m.id] = m;
      }
      if (m.id > _lastId) _lastId = m.id;
    }
  }

  Future<void> _history() async {
    final r = await _service.poll(widget.username, history: true);
    _since = r.serverTime;
    if (!mounted) return;
    setState(() {
      _merge(r.messages);
      _typing = r.typing;
    });
    _toBottom();
  }

  /// Long-polling: the server holds each request up to 12 seconds if there is
  /// nothing new, so this costs very few requests.
  Future<void> _loop() async {
    var failures = 0;
    while (_alive && mounted) {
      try {
        final r = await _service.poll(widget.username, afterId: _lastId, since: _since, waitSeconds: 12);
        failures = 0;
        if (!_alive || !mounted) return;
        _since = r.serverTime;
        final before = _messages.length;
        setState(() {
          _merge(r.messages);
          _typing = r.typing;
        });
        if (_messages.length != before) _toBottom();
        if (r.typing) await Future<void>.delayed(const Duration(seconds: 2));
      } catch (_) {
        failures++;
        await Future<void>.delayed(Duration(seconds: failures > 3 ? 15 : 4));
      }
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (override == null) _input.clear();
    setState(() => _sending = true);
    try {
      final id = await _service.send(widget.username, text, fromName: (_bot?.rule('shareUsername') ?? false) ? _myName : null);
      if (!mounted) return;
      setState(() => _merge([
            BotMessage(id: id, fromBot: false, kind: 'text', body: text, extra: {}, edited: false, deleted: false, createdAt: DateTime.now()),
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

  Future<void> _tapButton(BotMessage m, Map button) async {
    final url = button['url'];
    if (url is String) {
      await openMessageLink(context, url);
      return;
    }
    final data = button['callback_data'];
    if (data is String) {
      try {
        await _service.sendCallback(widget.username, data, m.id);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _showCommands() {
    final cmds = _bot?.commands ?? const <BotCommand>[];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in cmds)
              ListTile(
                title: Text('/${c.command}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: c.description.isEmpty ? null : Text(c.description),
                onTap: () {
                  Navigator.pop(ctx);
                  _send('/${c.command}');
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'info':
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(_bot?.name ?? ''),
            content: Text('@${widget.username}\n\n${(_bot?.description ?? '').isEmpty ? 'No description.' : _bot!.description}'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          ),
        );
        break;
      case 'report':
        await showReportBotDialog(context, widget.username);
        break;
      case 'clear':
        await _service.clearChat(widget.username);
        if (mounted) setState(() => _messages.clear());
        break;
      case 'block':
        final block = !(_bot?.blocked ?? false);
        await _service.setBlocked(widget.username, block);
        if (mounted) {
          setState(() => _bot = _bot!.copyWith(blocked: block));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(block ? 'Bot blocked' : 'Bot unblocked')));
        }
        break;
    }
  }

  /// The reply keyboard the bot last showed (until it removes it), and the
  /// "/" suggestions while typing a command.
  List<Widget> _composerExtras(BotInfo bot, List<BotMessage> list, ColorScheme scheme) {
    final out = <Widget>[];
    if (bot.blocked) return out;
    // Latest bot message that set or cleared a keyboard.
    List<List<String>> keyboard = const [];
    if (bot.rule('buttons')) {
      for (final m in list.reversed) {
        if (!m.fromBot || m.deleted) continue;
        final kb = m.extra['keyboard'];
        if (kb is List) {
          keyboard = [for (final row in kb) [for (final b in (row as List)) '$b']];
          break;
        }
      }
    }
    final typed = _input.text;
    final cmds = bot.rule('commandsMenu') ? bot.commands : const <BotCommand>[];
    if (typed.startsWith('/') && !typed.contains(' ') && cmds.isNotEmpty) {
      final q = typed.substring(1).toLowerCase();
      final matches = cmds.where((c) => c.command.startsWith(q)).take(6).toList();
      if (matches.isNotEmpty) {
        out.add(Container(
          constraints: const BoxConstraints(maxHeight: 230),
          color: scheme.surfaceContainerHigh,
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final c in matches)
                ListTile(
                  dense: true,
                  title: Text('/${c.command}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: c.description.isEmpty ? null : Text(c.description),
                  onTap: () {
                    _input.clear();
                    _send('/${c.command}');
                  },
                ),
            ],
          ),
        ));
      }
    } else if (keyboard.isNotEmpty) {
      out.add(Container(
        width: double.infinity,
        color: scheme.surfaceContainerHigh,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        child: Column(
          children: [
            for (final row in keyboard)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    for (final b in row)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: FilledButton.tonal(
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                            onPressed: _sending ? null : () => _send(b),
                            child: Text(b, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ));
    }
    return out;
  }

  /// **bold**, _italic_ and `code` — only when the bot's owner turned
  /// formatting on.
  List<InlineSpan> _formatted(String text, TextStyle base, ColorScheme scheme) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|_(.+?)_|`(.+?)`|(https?://[^\s]+)');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: base));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: base.copyWith(fontWeight: FontWeight.w800)));
      } else if (m.group(2) != null) {
        spans.add(TextSpan(text: m.group(2), style: base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(3) != null) {
        spans.add(TextSpan(text: m.group(3), style: base.copyWith(fontFamily: 'monospace', backgroundColor: scheme.surfaceContainerHighest)));
      } else {
        final url = m.group(4)!;
        spans.add(TextSpan(
          text: url,
          style: base.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => openMessageLink(context, url),
        ));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: base));
    return spans;
  }

  Widget _bubble(BotMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final mine = !m.fromBot;
    final base = TextStyle(color: mine ? scheme.onPrimaryContainer : scheme.onSurface, fontSize: 15.5);
    final buttons = (m.extra['buttons'] as List?)?.map((r) => (r as List).cast<Map>()).toList() ?? const <List<Map>>[];
    final photo = m.extra['photo'];
    final formatting = (_bot?.rule('formatting') ?? false) && m.fromBot;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: m.deleted
                  ? Text('Message deleted', style: base.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (photo is String && photo.startsWith('https://'))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(photo, width: 240, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const SizedBox(height: 60, child: Center(child: Icon(Icons.broken_image_outlined)))),
                            ),
                          ),
                        if (m.body.isNotEmpty)
                          formatting
                              ? Text.rich(TextSpan(children: _formatted(m.body, base, scheme)))
                              : SelectableText(m.body, style: base),
                        if (m.edited)
                          Text('edited', style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
                      ],
                    ),
            ),
            if (!m.deleted && (_bot?.rule('buttons') ?? false))
              for (final row in buttons)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final b in row)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () => _tapButton(m, b),
                        child: Text('${b['text']}'),
                      ),
                  ],
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bot = _bot;
    final blocked = bot?.blocked ?? false;
    final list = _messages.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            BotAvatar(photoData: bot?.photoData, name: bot?.name ?? '', radius: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(child: Text(bot?.name ?? widget.username, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
                    const SizedBox(width: 6),
                    const BotBadge(),
                  ]),
                  Text(_typing ? 'typing…' : 'bot', style: TextStyle(fontSize: 12, color: _typing ? scheme.primary : scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'info', child: Text('Bot info')),
              const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
              PopupMenuItem(value: 'block', child: Text(blocked ? 'Unblock bot' : 'Block bot')),
              const PopupMenuItem(value: 'report', child: Text('Report bot')),
            ],
          ),
        ],
      ),
      body: _loadError != null
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_loadError!, textAlign: TextAlign.center)))
          : bot == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (_showNotice)
                      Container(
                        width: double.infinity,
                        color: scheme.secondaryContainer,
                        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 18, color: scheme.onSecondaryContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Bot chats are not end-to-end encrypted. The bot and its owner can read what you send — never share passwords or private details.',
                                style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.close, size: 18, color: scheme.onSecondaryContainer),
                              onPressed: () => setState(() => _showNotice = false),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: list.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  BotAvatar(photoData: bot.photoData, name: bot.name, radius: 40),
                                  const SizedBox(height: 12),
                                  Text(bot.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                  if (bot.description.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(bot.description, textAlign: TextAlign.center),
                                  ],
                                  const SizedBox(height: 10),
                                  const Text('Say hello to start.', style: TextStyle(fontSize: 12.5)),
                                ]),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.all(12),
                              itemCount: list.length,
                              itemBuilder: (_, i) => _bubble(list[list.length - 1 - i]),
                            ),
                    ),
                    ..._composerExtras(bot, list, scheme),
                    SafeArea(
                      top: false,
                      child: blocked
                          ? Padding(padding: const EdgeInsets.all(14), child: Text('You blocked this bot.', style: TextStyle(color: scheme.onSurfaceVariant)))
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                              child: Row(
                                children: [
                                  if (bot.rule('commandsMenu') && bot.commands.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: FilledButton.tonalIcon(
                                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                                        onPressed: _showCommands,
                                        icon: const Icon(Icons.menu_rounded, size: 18),
                                        label: const Text('Menu'),
                                      ),
                                    ),
                                  Expanded(
                                    child: TextField(
                                      controller: _input,
                                      minLines: 1,
                                      maxLines: 5,
                                      maxLength: 4000,
                                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                                      textInputAction: TextInputAction.newline,
                                      decoration: InputDecoration(
                                        hintText: 'Message',
                                        filled: true,
                                        fillColor: scheme.surfaceContainerHigh,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton.filled(onPressed: _sending ? null : () => _send(), icon: const Icon(Icons.send_rounded)),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}
