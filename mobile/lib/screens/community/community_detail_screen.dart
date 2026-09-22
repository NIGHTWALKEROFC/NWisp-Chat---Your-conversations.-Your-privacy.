import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/community_service.dart';
import '../../services/group_service.dart';
import '../groups/group_chat_screen.dart';
import '../groups/report_group_screen.dart';
import '../security/chat_pin_guard.dart';
import 'community_widgets.dart';
import 'create_community_screen.dart';

/// A community's public page: what it is, where it is, its rules — and
/// Join / Open chat. Visible to everyone, member or not.
class CommunityDetailScreen extends StatefulWidget {
  final CommunityListing listing;
  const CommunityDetailScreen({super.key, required this.listing});

  @override
  State<CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<CommunityDetailScreen> {
  bool _busy = false;
  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openChat(CommunityListing c) async {
    if (!await requireChatPinIfLocked(context, c.id)) return;
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: c.id)));
  }

  Future<void> _join(CommunityListing c) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Join ${c.name}?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.rules.trim().isNotEmpty) ...[
                const Text('Community rules', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(c.rules.trim()),
                const SizedBox(height: 12),
              ],
              Text(
                '• Members can see your username.\n'
                '• You will only see messages sent after you join.\n'
                '• Messages are not stored on any server — they are saved only on members\' phones.\n'
                '• You can leave or report this community at any time.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await CommunityService.instance.join(c.id);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('You joined ${c.name}');
      await _openChat(c);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack("Couldn't join — the community may be full, or you may have been removed from it.");
    }
  }

  Future<void> _leave(CommunityListing c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Leave ${c.name}?'),
        content: const Text('You will stop receiving its messages, and the copy on this phone is removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await CommunityService.instance.leave(c.id);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack("Couldn't leave — check your connection and try again.");
    }
  }

  Future<void> _report(CommunityListing c) async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ReportGroupScreen(groupId: c.id, groupName: c.name)),
    );
    if (sent == true) _snack('Report sent. Thank you — we will review it.');
  }

  Future<void> _edit(CommunityListing c) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CreateCommunityScreen(editing: c)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<CommunityListing?>(
      stream: CommunityService.instance.listingStream(widget.listing.id),
      initialData: widget.listing,
      builder: (context, listingSnap) {
        final c = listingSnap.data;
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This community no longer exists.')),
          );
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: GroupService.instance.myGroupsStream(),
          builder: (context, groupsSnap) {
            Map<String, dynamic>? mine;
            for (final d in groupsSnap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
              if (d.id == c.id) mine = d.data();
            }
            final mineData = mine;
            final isMember = mineData != null;
            final isAdmin = mineData != null && List<String>.from(mineData['admins'] ?? const []).contains(_myUid);
            return Scaffold(
              appBar: AppBar(
                title: const Text('Community'),
                actions: [
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'report') _report(c);
                      if (v == 'edit') _edit(c);
                      if (v == 'leave') _leave(c);
                    },
                    itemBuilder: (_) => [
                      if (isAdmin) const PopupMenuItem(value: 'edit', child: Text('Edit community')),
                      const PopupMenuItem(value: 'report', child: Text('Report community')),
                      if (isMember) const PopupMenuItem(value: 'leave', child: Text('Leave community')),
                    ],
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(child: CommunityAvatar(url: c.avatarUrl, radius: 48)),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(c.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 10),
                  Center(child: CommunityFacts(listing: c)),
                  const SizedBox(height: 20),
                  if (c.description.trim().isNotEmpty) ...[
                    Text('About', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
                    const SizedBox(height: 4),
                    Text(c.description.trim()),
                    const SizedBox(height: 18),
                  ],
                  if (c.rules.trim().isNotEmpty) ...[
                    Text('Rules', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                      child: Text(c.rules.trim()),
                    ),
                    const SizedBox(height: 18),
                  ],
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Messages are end-to-end encrypted and never stored on a server — only on members\' phones. '
                            'New members see only messages sent after they join.',
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (isMember)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _openChat(c),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Open chat'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: (_busy || c.isFull) ? null : () => _join(c),
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.group_add_outlined),
                      label: Text(c.isFull ? 'Community is full' : 'Join community'),
                    ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () => _report(c),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Report this community'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
