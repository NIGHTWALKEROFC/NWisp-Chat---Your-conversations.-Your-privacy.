import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/chat_folder_service.dart';
import '../services/local_message_store.dart';

/// Feature: chat folders/categories. Manage the folders themselves here
/// (create/rename/delete); chat_list_screen.dart reads
/// ChatFolderService.watchFolders() to show a filter row of tabs above
/// the chat list whenever at least one folder exists.
class ChatFoldersScreen extends StatefulWidget {
  const ChatFoldersScreen({super.key});

  @override
  State<ChatFoldersScreen> createState() => _ChatFoldersScreenState();
}

class _ChatFoldersScreenState extends State<ChatFoldersScreen> {
  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Work, Family, Close friends')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ChatFolderService.createFolder(name);
  }

  Future<void> _rename(ChatFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ChatFolderService.renameFolder(folder.id, name);
  }

  Future<void> _delete(ChatFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: const Text('The chats inside it are not affected — this only removes the folder itself.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) await ChatFolderService.deleteFolder(folder.id);
  }

  void _editChats(ChatFolder folder) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => _FolderChatPickerScreen(folder: folder)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat folders'),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: 'New folder', onPressed: _createFolder)],
      ),
      body: StreamBuilder<List<ChatFolder>>(
        stream: ChatFolderService.watchFolders(),
        builder: (context, snapshot) {
          final folders = snapshot.data ?? [];
          if (folders.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_outlined, size: 48, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(
                      'No folders yet — group your chats into folders like "Work" or "Family" to filter your chat list',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: _createFolder, icon: const Icon(Icons.add), label: const Text('Create a folder')),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: folders.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final f = folders[i];
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f.name),
                subtitle: Text('${f.conversationIds.length} chat${f.conversationIds.length == 1 ? '' : 's'}'),
                onTap: () => _editChats(f),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') _rename(f);
                    if (v == 'delete') _delete(f);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _FolderChatPickerScreen extends StatefulWidget {
  final ChatFolder folder;
  const _FolderChatPickerScreen({required this.folder});

  @override
  State<_FolderChatPickerScreen> createState() => _FolderChatPickerScreenState();
}

class _FolderChatPickerScreenState extends State<_FolderChatPickerScreen> {
  List<ConversationSummary> _summaries = [];
  final Map<String, String> _usernameCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// BUGFIX (folder audit): this used to source its list ONLY from
  /// LocalMessageStore.watchSummaries(), which is derived from the local
  /// `messages` table — so a brand-new chat or group with ZERO messages
  /// sent or received yet never showed up here at all, and couldn't be
  /// added to a folder. Now also pulls every group and 1:1 conversation
  /// the person is actually part of, straight from Firestore, and merges
  /// the two lists (by conversationId) so an empty chat/group appears
  /// too — with an empty preview, but fully assignable.
  Future<void> _load() async {
    final fromMessages = await LocalMessageStore.watchSummaries().first;
    final byId = {for (final s in fromMessages) s.conversationId: s};
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid != null) {
      final groupsSnap = await FirebaseFirestore.instance.collection('groups').where('members', arrayContains: myUid).get();
      for (final doc in groupsSnap.docs) {
        byId.putIfAbsent(
          doc.id,
          () => ConversationSummary(conversationId: doc.id, peerUid: '', lastText: '', lastAt: DateTime.now(), unreadCount: 0, isGroup: true, groupName: (doc.data()['name'] as String?) ?? 'Group'),
        );
      }
      final convosSnap = await FirebaseFirestore.instance.collection('conversations').where('participants', arrayContains: myUid).get();
      for (final doc in convosSnap.docs) {
        final participants = List<String>.from(doc.data()['participants'] ?? []);
        final peer = participants.firstWhere((p) => p != myUid, orElse: () => '');
        if (peer.isEmpty) continue;
        byId.putIfAbsent(
          doc.id,
          () => ConversationSummary(conversationId: doc.id, peerUid: peer, lastText: '', lastAt: DateTime.now(), unreadCount: 0, isGroup: false),
        );
      }
    }
    if (mounted) setState(() => _summaries = byId.values.toList());
  }

  Future<String> _labelFor(ConversationSummary s) async {
    if (s.isGroup) return s.groupName ?? 'Group';
    if (_usernameCache.containsKey(s.peerUid)) return _usernameCache[s.peerUid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(s.peerUid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[s.peerUid] = name;
    return name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.folder.name} — pick chats')),
      body: StreamBuilder<List<ChatFolder>>(
        stream: ChatFolderService.watchFolders(),
        builder: (context, snapshot) {
          final current = (snapshot.data ?? const []).firstWhere(
            (f) => f.id == widget.folder.id,
            orElse: () => widget.folder,
          );
          return ListView.builder(
            itemCount: _summaries.length,
            itemBuilder: (context, i) {
              final s = _summaries[i];
              final included = current.conversationIds.contains(s.conversationId);
              return FutureBuilder<String>(
                future: _labelFor(s),
                builder: (context, nameSnap) => CheckboxListTile(
                  secondary: Icon(s.isGroup ? Icons.groups_rounded : Icons.person),
                  title: Text(nameSnap.data ?? '…'),
                  value: included,
                  onChanged: (v) => ChatFolderService.setConversationInFolder(widget.folder.id, s.conversationId, v ?? false),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
