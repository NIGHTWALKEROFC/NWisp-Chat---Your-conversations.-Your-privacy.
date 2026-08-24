import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/group.dart';
import '../../services/contact_service.dart';
import '../../services/group_service.dart';
import '../../services/media_service.dart';
import '../chat_list_screen.dart';

const _groupTtlOptions = [0, 1, 6, 24, 72, 168]; // 0 = never, hours after that

class GroupInfoScreen extends StatefulWidget {
  final String groupId;
  const GroupInfoScreen({super.key, required this.groupId});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  final _contactService = ContactService();
  final Map<String, String> _usernames = {};
  bool _busy = false;

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  Future<String> _usernameFor(String uid) async {
    if (_usernames.containsKey(uid)) return _usernames[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernames[uid] = name;
    return name;
  }

  Future<void> _rename(Group group) async {
    final controller = TextEditingController(text: group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Group name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await GroupService.instance.renameGroup(widget.groupId, name);
  }

  Future<void> _changeAvatar() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final url = await MediaService.uploadGroupAvatar(File(picked.path), widget.groupId);
      await GroupService.instance.updateAvatar(widget.groupId, url);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't update the photo: $e")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMembers(Group group) async {
    final contactSnap = await _contactService.contactsStream().first;
    final candidates = contactSnap.docs.where((d) => !group.members.contains(d.id)).toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All your contacts are already in this group.')));
      return;
    }
    final selected = <String>{};
    final toAdd = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(alignment: Alignment.centerLeft, child: Text('Add members', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: candidates.map((d) {
                    final uid = d.id;
                    final username = (d.data()['username'] as String?) ?? 'Unknown';
                    return CheckboxListTile(
                      value: selected.contains(uid),
                      title: Text(username),
                      onChanged: (checked) => setSheetState(() {
                        if (checked == true) {
                          selected.add(uid);
                        } else {
                          selected.remove(uid);
                        }
                      }),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheetContext, selected),
                  child: const Text('Add selected'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (toAdd == null || toAdd.isEmpty) return;
    await GroupService.instance.addMembers(widget.groupId, toAdd.toList());
  }

  Future<void> _removeMember(String uid, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text('Remove $username from this group?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await GroupService.instance.removeMember(widget.groupId, uid);
  }

  Future<void> _leave(Group group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave group?'),
        content: Text(
          group.isOwner(_myUid) && group.members.length > 1
              ? "You're the owner — leaving hands ownership to another member."
              : "You'll stop receiving messages from this group.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await GroupService.instance.leaveGroup(widget.groupId);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ChatListScreen()));
  }

  void _openTtlPicker(Group group) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Auto-delete for this group', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
            ),
            for (final hours in _groupTtlOptions)
              RadioListTile<int>(
                value: hours,
                groupValue: group.chatTtlHours ?? 0,
                title: Text(
                  hours == 0
                      ? 'Never'
                      : (hours < 24 ? '$hours hour${hours == 1 ? '' : 's'}' : '${hours ~/ 24} day${hours ~/ 24 == 1 ? '' : 's'}'),
                ),
                onChanged: (value) async {
                  await GroupService.instance.setChatTtlHours(widget.groupId, value);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: GroupService.instance.groupStream(widget.groupId),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final group = Group.fromDoc(snapshot.data!);
          final amAdmin = group.isAdmin(_myUid);
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: amAdmin && !_busy ? _changeAvatar : null,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 44,
                            backgroundColor: scheme.primaryContainer,
                            backgroundImage: group.avatarUrl != null ? NetworkImage(group.avatarUrl!) : null,
                            child: group.avatarUrl == null ? const Icon(Icons.groups_rounded, size: 36) : null,
                          ),
                          if (amAdmin)
                            CircleAvatar(radius: 14, backgroundColor: scheme.primary, child: const Icon(Icons.edit, size: 14, color: Colors.white)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(group.name, style: Theme.of(context).textTheme.titleLarge),
                        if (amAdmin)
                          IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _rename(group)),
                      ],
                    ),
                    Text('${group.members.length} members', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Auto-delete messages'),
                subtitle: Text(group.chatTtlHours == null || group.chatTtlHours == 0 ? 'Never' : '${group.chatTtlHours} hours'),
                onTap: amAdmin ? () => _openTtlPicker(group) : null,
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Members', style: Theme.of(context).textTheme.titleSmall),
                    if (amAdmin)
                      TextButton.icon(
                        onPressed: () => _addMembers(group),
                        icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                        label: const Text('Add'),
                      ),
                  ],
                ),
              ),
              for (final uid in group.members)
                FutureBuilder<String>(
                  future: _usernameFor(uid),
                  builder: (context, nameSnap) {
                    final username = nameSnap.data ?? '…';
                    final isOwnerRow = group.isOwner(uid);
                    final isAdminRow = group.isAdmin(uid);
                    return ListTile(
                      leading: CircleAvatar(child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?')),
                      title: Text(uid == _myUid ? '$username (you)' : username),
                      subtitle: Text(isOwnerRow ? 'Owner' : (isAdminRow ? 'Admin' : 'Member')),
                      trailing: (amAdmin && uid != _myUid)
                          ? PopupMenuButton<String>(
                              onSelected: (action) {
                                switch (action) {
                                  case 'promote':
                                    GroupService.instance.promoteAdmin(widget.groupId, uid);
                                    break;
                                  case 'demote':
                                    GroupService.instance.demoteAdmin(widget.groupId, uid);
                                    break;
                                  case 'remove':
                                    _removeMember(uid, username);
                                    break;
                                }
                              },
                              itemBuilder: (context) => [
                                if (!isAdminRow) const PopupMenuItem(value: 'promote', child: Text('Make admin')),
                                if (isAdminRow && !isOwnerRow) const PopupMenuItem(value: 'demote', child: Text('Remove as admin')),
                                if (!isOwnerRow) const PopupMenuItem(value: 'remove', child: Text('Remove from group')),
                              ],
                            )
                          : null,
                    );
                  },
                ),
              const Divider(),
              ListTile(
                leading: Icon(Icons.exit_to_app, color: scheme.error),
                title: Text('Leave group', style: TextStyle(color: scheme.error)),
                onTap: () => _leave(group),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
