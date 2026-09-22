import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/chat_lock_service.dart';
import '../services/group_service.dart';
import '../services/local_message_store.dart';
import '../widgets/mute_duration_sheet.dart';
import 'community/community_widgets.dart';
import 'groups/group_chat_screen.dart';
import 'security/chat_pin_guard.dart';

/// The "Announcements" tab: every group where only admins can post, kept
/// out of the Chats list so the home screen stays clean. Members can still
/// react to a post or reply privately to whoever posted it.
///
/// Mute or leave any of them with a long-press. The whole tab can be
/// switched off in Settings > Chats (then these groups simply appear in
/// Chats again, like any other group).
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _groups = [];
  List<ConversationSummary> _summaries = [];
  Set<String> _hiddenIds = {};
  bool _loaded = false;
  StreamSubscription? _groupsSub;
  StreamSubscription? _summarySub;

  @override
  void initState() {
    super.initState();
    _loadHidden();
    _groupsSub = GroupService.instance.myGroupsStream().listen((snap) {
      if (!mounted) return;
      setState(() {
        _groups = snap.docs.where((d) {
          final data = d.data();
          return data['onlyAdminsCanSend'] == true && data['isCommunity'] != true;
        }).toList();
        _loaded = true;
      });
    });
    _summarySub = LocalMessageStore.watchSummaries().listen((list) {
      if (mounted) setState(() => _summaries = list);
    });
  }

  @override
  void dispose() {
    _groupsSub?.cancel();
    _summarySub?.cancel();
    super.dispose();
  }

  Future<void> _loadHidden() async {
    final ids = await ChatLockService.getAllHiddenIds();
    if (mounted) setState(() => _hiddenIds = ids);
  }

  ConversationSummary? _summaryFor(String id) {
    for (final s in _summaries) {
      if (s.conversationId == id) return s;
    }
    return null;
  }

  Future<void> _open(String groupId) async {
    if (!await canOpenChat(context, conversationId: groupId)) return;
    if (!mounted) return;
    if (!await requireChatPinIfLocked(context, groupId)) return;
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId)));
    await _loadHidden();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _options(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final data = doc.data();
    final muted = GroupService.instance.isMutedByMe(data);
    final name = (data['name'] as String?) ?? 'Group';
    final error = Theme.of(context).colorScheme.error;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(muted ? 'Unmute' : 'Mute…'),
              onTap: () => Navigator.pop(sheetContext, 'mute'),
            ),
            ListTile(
              leading: Icon(Icons.exit_to_app, color: error),
              title: Text('Exit $name', style: TextStyle(color: error)),
              onTap: () => Navigator.pop(sheetContext, 'leave'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action == 'mute') {
        if (muted) {
          await GroupService.instance.setMuted(doc.id, false);
          _snack('Notifications are back on');
        } else {
          final choice = await showMuteDurationSheet(context);
          if (choice == null) return;
          if (choice.isForever) {
            await GroupService.instance.setMuted(doc.id, true);
          } else {
            await GroupService.instance.muteFor(doc.id, choice.duration!);
          }
          _snack('Muted ${choice.label}');
        }
      } else if (action == 'leave') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Exit $name?'),
            content: const Text('You will stop receiving its announcements, and the copy on this phone is removed.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Exit')),
            ],
          ),
        );
        if (ok == true) await GroupService.instance.leaveGroup(doc.id);
      }
    } catch (_) {
      _snack("That didn't work — check your connection and try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _groups.where((d) => !_hiddenIds.contains(d.id)).toList()
      ..sort((a, b) {
        final aa = _summaryFor(a.id)?.lastAt ?? (a.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bb = _summaryFor(b.id)?.lastAt ?? (b.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bb.compareTo(aa);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Announcements')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.campaign_outlined, size: 72, color: scheme.primary.withValues(alpha: 0.5)),
                        const SizedBox(height: 16),
                        Text('No announcements', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(
                          'Groups where only admins can post will show up here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                      child: Text(
                        'Only admins can post in these. You can react, or reply privately. Long-press one to mute or exit.',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    for (final doc in visible) _tile(scheme, doc),
                  ],
                ),
    );
  }

  Widget _tile(ColorScheme scheme, QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final name = (data['name'] as String?) ?? 'Group';
    final summary = _summaryFor(doc.id);
    final unread = summary?.unreadCount ?? 0;
    final muted = GroupService.instance.isMutedByMe(data);
    return ListTile(
      leading: CommunityAvatar(url: data['avatarUrl'] as String?, radius: 24),
      title: Text(name, style: unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null),
      subtitle: Text(
        summary?.lastText ?? 'No announcements yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: summary == null ? TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic) : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (muted) Icon(Icons.notifications_off, size: 16, color: scheme.onSurfaceVariant),
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: CircleAvatar(
                radius: 11,
                backgroundColor: scheme.primary,
                child: Text('$unread', style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
      onTap: () => _open(doc.id),
      onLongPress: () => _options(doc),
    );
  }
}
