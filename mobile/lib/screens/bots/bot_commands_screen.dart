import 'package:flutter/material.dart';
import '../../services/bot_service.dart';

/// Edit the "/" command menu of one of my bots (also settable by the bot
/// itself through setMyCommands). Shown in the chat only while the
/// "Command menu" rule is on.
class BotCommandsScreen extends StatefulWidget {
  final BotInfo bot;
  const BotCommandsScreen({super.key, required this.bot});

  @override
  State<BotCommandsScreen> createState() => _BotCommandsScreenState();
}

class _Row {
  final TextEditingController command;
  final TextEditingController description;
  _Row(String c, String d)
      : command = TextEditingController(text: c),
        description = TextEditingController(text: d);
  void dispose() {
    command.dispose();
    description.dispose();
  }
}

class _BotCommandsScreenState extends State<BotCommandsScreen> {
  late final List<_Row> _rows = [for (final c in widget.bot.commands) _Row(c.command, c.description)];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final list = <BotCommand>[];
    final seen = <String>{};
    for (final r in _rows) {
      final c = r.command.text.trim().toLowerCase().replaceFirst('/', '');
      if (c.isEmpty) continue;
      if (!RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(c)) {
        setState(() => _error = '"/$c" — use only lowercase letters, numbers and underscores.');
        return;
      }
      if (!seen.add(c)) {
        setState(() => _error = '"/$c" is listed twice.');
        return;
      }
      list.add(BotCommand(c, r.description.text.trim()));
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BotService.instance.setCommands(widget.bot.username, list);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Command menu'), actions: [
        TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!widget.bot.rule('commandsMenu'))
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Text('The "Command menu" rule is off, so people won\'t see these yet. Turn it on in the bot\'s rules.',
                  style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13)),
            ),
          const Text('People tap the Menu button (or type "/") to see these. Up to 30.', style: TextStyle(fontSize: 12.5)),
          const SizedBox(height: 10),
          for (var i = 0; i < _rows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _rows[i].command,
                      autocorrect: false,
                      decoration: const InputDecoration(prefixText: '/', labelText: 'command', border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rows[i].description,
                      maxLength: 100,
                      decoration: const InputDecoration(labelText: 'what it does', border: OutlineInputBorder(), isDense: true, counterText: ''),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _rows.removeAt(i).dispose()),
                  ),
                ],
              ),
            ),
          OutlinedButton.icon(
            onPressed: _rows.length >= 30 ? null : () => setState(() => _rows.add(_Row('', ''))),
            icon: const Icon(Icons.add),
            label: const Text('Add command'),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: scheme.error))),
        ],
      ),
    );
  }
}
