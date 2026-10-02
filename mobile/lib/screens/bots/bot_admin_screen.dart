import 'package:flutter/material.dart';
import '../../services/bot_service.dart';

/// Moderation: bots people have reported. Only shown to accounts listed in the
/// BOT_ADMIN_UIDS secret on the server (the server re-checks every action).
class BotAdminScreen extends StatefulWidget {
  const BotAdminScreen({super.key});

  @override
  State<BotAdminScreen> createState() => _BotAdminScreenState();
}

class _BotAdminScreenState extends State<BotAdminScreen> {
  List<BotReportItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await BotService.instance.adminReports();
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _act(BotReportItem i, String status) async {
    String reason = '';
    if (status != 'active') {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(status == 'banned' ? 'Ban @${i.username}?' : 'Suspend @${i.username}?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(status == 'banned'
                ? 'The bot stops working for good, disappears from search and chats, and its owner is told why.'
                : 'The bot stops working until you restore it. Its owner is told why.'),
            const SizedBox(height: 10),
            TextField(controller: c, maxLength: 200, decoration: const InputDecoration(labelText: 'Reason shown to the owner', border: OutlineInputBorder())),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(status == 'banned' ? 'Ban' : 'Suspend'),
            ),
          ],
        ),
      );
      reason = c.text.trim();
      c.dispose();
      if (ok != true) return;
    }
    try {
      await BotService.instance.adminSetStatus(i.username, status, reason: reason);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Color _statusColor(String s, ColorScheme c) => s == 'banned' ? c.error : (s == 'suspended' ? Colors.orange : Colors.green);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reported bots'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : _items == null
              ? const Center(child: CircularProgressIndicator())
              : _items!.isEmpty
                  ? const Center(child: Text('No open reports 🎉'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _items!.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, n) {
                        final i = _items![n];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(child: Text('${i.name}  ·  @${i.username}', style: const TextStyle(fontWeight: FontWeight.w800))),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(color: _statusColor(i.status, scheme).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
                                    child: Text(i.status, style: TextStyle(color: _statusColor(i.status, scheme), fontWeight: FontWeight.w700, fontSize: 12)),
                                  ),
                                ]),
                                const SizedBox(height: 6),
                                Text('${i.count} report${i.count == 1 ? '' : 's'}: ${i.reasons.entries.map((e) => '${BotService.reportReasons[e.key] ?? e.key} ×${e.value}').join(', ')}'),
                                for (final d in i.details)
                                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('“$d”', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))),
                                const SizedBox(height: 10),
                                Wrap(spacing: 8, runSpacing: 6, children: [
                                  OutlinedButton(onPressed: () => _act(i, 'suspended'), child: const Text('Suspend')),
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                                    onPressed: () => _act(i, 'banned'),
                                    child: const Text('Ban'),
                                  ),
                                  FilledButton.tonal(onPressed: () => _act(i, 'active'), child: const Text('Restore & clear')),
                                  TextButton(
                                    onPressed: () async {
                                      await BotService.instance.adminDismiss(i.username);
                                      _load();
                                    },
                                    child: const Text('Dismiss reports'),
                                  ),
                                ]),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
