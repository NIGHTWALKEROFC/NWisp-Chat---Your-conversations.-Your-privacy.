import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/broadcast_list_service.dart';
import 'create_broadcast_list_screen.dart';

/// Feature: broadcast lists — the "compose and send" screen for one list.
/// Deliberately NOT built like ChatDetailScreen: there is no shared thread
/// to show here (see BroadcastListService's doc comment for why), so this
/// is a simple composer plus a local log of what YOU previously sent to
/// this list and how many of its members it reached — replies from members
/// show up as ordinary messages in your normal 1:1 chat with each of them,
/// not here.
class BroadcastListScreen extends StatefulWidget {
  final String listId;
  const BroadcastListScreen({super.key, required this.listId});

  @override
  State<BroadcastListScreen> createState() => _BroadcastListScreenState();
}

class _BroadcastListScreenState extends State<BroadcastListScreen> {
  final _textController = TextEditingController();
  BroadcastList? _list;
  List<BroadcastHistoryEntry> _history = [];
  final Map<String, String> _usernameCache = {};
  bool _sending = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final lists = await BroadcastListService.getLists();
    final list = lists.where((l) => l.id == widget.listId).cast<BroadcastList?>().firstWhere((_) => true, orElse: () => null);
    final history = await BroadcastListService.getHistory(widget.listId);
    if (!mounted) return;
    setState(() {
      _list = list;
      _history = history;
      _loading = false;
    });
  }

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  Future<void> _send() async {
    final list = _list;
    final text = _textController.text.trim();
    if (list == null || text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final outcomes = await BroadcastListService.sendToList(list, text);
      final failed = outcomes.where((o) => !o.success).toList();
      _textController.clear();
      await _load();
      if (!mounted) return;
      if (failed.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sent to all ${outcomes.length} recipients')),
        );
      } else {
        final names = await Future.wait(failed.map((o) => _usernameFor(o.memberUid)));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Sent, but didn't reach: ${names.join(', ')}")),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't send: $e")));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirmDelete() async {
    final list = _list;
    if (list == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this broadcast list?'),
        content: Text('"${list.name}" and its send history will be removed. This only deletes the list itself — '
            "it doesn't delete any messages you've already sent."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await BroadcastListService.deleteList(list.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final list = _list;
    if (list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Broadcast list')),
        body: const Center(child: Text('This list no longer exists.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(list.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => CreateBroadcastListScreen(existing: list))).then((_) => _load());
              } else if (value == 'delete') {
                _confirmDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit recipients')),
              PopupMenuItem(value: 'delete', child: Text('Delete list')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FutureBuilder<List<String>>(
              future: Future.wait(list.memberUids.map(_usernameFor)),
              builder: (context, snap) {
                final names = snap.data?.join(', ') ?? '${list.memberUids.length} recipients';
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${list.memberUids.length} recipients: $names',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        "Nothing sent to this list yet. Type a message below — it'll go out to every "
                        "recipient's normal chat with you, as an ordinary message.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: _history.length,
                    itemBuilder: (context, i) {
                      final entry = _history[i];
                      final allOk = entry.failCount == 0;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.text),
                              const SizedBox(height: 6),
                              Text(
                                '${TimeOfDay.fromDateTime(entry.sentAt).format(context)} · '
                                '${allOk ? 'Delivered to all ${entry.successCount}' : '${entry.successCount} delivered, ${entry.failCount} failed'}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: allOk ? scheme.onSurfaceVariant : scheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: 'Message this list…',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
