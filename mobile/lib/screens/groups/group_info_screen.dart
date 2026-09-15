import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/group.dart';
import '../../services/contact_service.dart';
import '../../services/group_service.dart';
import '../../services/inactivity_wipe_service.dart';
import '../../services/media_service.dart';
import '../chat_list_screen.dart';
import '../chat/chat_media_browser_screen.dart';
import '../chat/chat_wallpaper_screen.dart';
import '../settings/keyword_mute_screen.dart';
import 'report_group_screen.dart';
import '../security/safety_number_screen.dart';

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
  // Feature: inactivity auto-wipe, per-chat override — same shape as
  // chat_settings_screen.dart's own version of this.
  bool? _inactivityOverrideEnabled;
  int _inactivityOverrideMonths = 3;

  @override
  void initState() {
    super.initState();
    InactivityWipeService.getChatOverride(widget.groupId).then((override) {
      if (!mounted) return;
      setState(() {
        _inactivityOverrideEnabled = override?.enabled;
        _inactivityOverrideMonths = override?.months ?? 3;
      });
    });
  }

  String _inactivityOverrideLabel() {
    if (_inactivityOverrideEnabled == null) return "Follows your Settings > Auto-wipe inactive chats default";
    if (_inactivityOverrideEnabled == true) return "On for this group — clears after $_inactivityOverrideMonths month${_inactivityOverrideMonths == 1 ? '' : 's'} of not opening it, no matter the app default";
    return "Off for this group, even if the app default is on";
  }

  Future<void> _pickInactivityOverride() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Auto-wipe if inactive'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'default'), child: const Text('Follow app default')),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'off'), child: const Text('Off for this group')),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'on'), child: const Text('On for this group')),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'default') {
      await InactivityWipeService.clearChatOverride(widget.groupId);
      if (mounted) setState(() => _inactivityOverrideEnabled = null);
      return;
    }
    if (choice == 'off') {
      await InactivityWipeService.setChatOverride(widget.groupId, false, _inactivityOverrideMonths);
      if (mounted) setState(() => _inactivityOverrideEnabled = false);
      return;
    }
    final months = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('After how long'),
        children: [1, 2, 3, 6, 12].map((m) {
          return SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, m), child: Text('$m month${m == 1 ? '' : 's'}'));
        }).toList(),
      ),
    );
    if (months == null) return;
    await InactivityWipeService.setChatOverride(widget.groupId, true, months);
    if (mounted) setState(() {
      _inactivityOverrideEnabled = true;
      _inactivityOverrideMonths = months;
    });
  }

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

  /// Admin-only, like [_rename] — see GroupService.updateDescription.
  Future<void> _editDescription(Group group) async {
    final controller = TextEditingController(text: group.description);
    final description = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Group description'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'What is this group for?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (description == null) return;
    await GroupService.instance.updateDescription(widget.groupId, description);
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

  /// For anyone who ISN'T already a contact — see GroupService.
  /// inviteToGroup's own doc comment for why this goes through a
  /// request/accept flow instead of adding them directly the way
  /// [_addMembers] does for contacts.
  Future<void> _inviteNonContact(Group group) async {
    final controller = TextEditingController();
    List<Map<String, dynamic>> results = [];
    final invited = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Invite someone else', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(
                        "They'll get an invite to accept or decline — they won't be added until they do.",
                        style: TextStyle(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Search by username', border: OutlineInputBorder()),
                        onChanged: (query) async {
                          final found = await _contactService.searchUsers(query);
                          setSheetState(() => results = found.where((u) => !group.members.contains(u['uid'])).toList());
                        },
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: results.map((u) {
                      final uid = u['uid'] as String;
                      final username = (u['username'] as String?) ?? 'Unknown';
                      return ListTile(
                        leading: CircleAvatar(child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?')),
                        title: Text(username),
                        trailing: FilledButton(
                          onPressed: () async {
                            try {
                              await GroupService.instance.inviteToGroup(
                                groupId: widget.groupId,
                                groupName: group.name,
                                groupAvatarUrl: group.avatarUrl,
                                toUid: uid,
                                toUsername: username,
                              );
                              if (sheetContext.mounted) Navigator.pop(sheetContext, true);
                            } catch (e) {
                              if (sheetContext.mounted) {
                                ScaffoldMessenger.of(sheetContext).showSnackBar(
                                  SnackBar(content: Text("Couldn't send invite: $e")),
                                );
                              }
                            }
                          },
                          child: const Text('Invite'),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (invited == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invite sent')));
    }
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

  /// Feature: ownership transfer. A deliberate handoff — separate from
  /// leaveGroup's automatic reassignment (which only kicks in when the
  /// owner actually leaves and just picks whichever admin comes first,
  /// not someone chosen). This closes the "sole owner loses their
  /// device" gap by letting an owner hand off BEFORE that happens, to
  /// whoever they actually want.
  Future<void> _confirmTransferOwnership(String uid, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Make group owner?'),
        content: Text(
          '$username becomes the group owner instead of you. They\'ll be made an admin if they aren\'t one already. '
          'You stay a member and admin — this only changes who owns the group.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Transfer')),
        ],
      ),
    );
    if (confirmed != true) return;
    await GroupService.instance.transferOwnership(widget.groupId, uid);
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
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: amAdmin ? () => _editDescription(group) : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          group.description.isEmpty
                              ? (amAdmin ? 'Add a group description' : '')
                              : group.description,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontStyle: group.description.isEmpty ? FontStyle.italic : FontStyle.normal,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Auto-delete messages'),
                subtitle: Text(group.chatTtlHours == null || group.chatTtlHours == 0 ? 'Never' : '${group.chatTtlHours} hours'),
                onTap: amAdmin ? () => _openTtlPicker(group) : null,
              ),
              // Feature: group security setting. Admin-only, same pattern
              // as the disappearing-messages setting above — the toggle
              // itself is only interactive for admins (onChanged: null
              // otherwise), and GroupService.setOnlyAdminsCanSend is
              // additionally only reachable via a firestore.rules write
              // that already requires isGroupAdmin() on this same
              // document, so a non-admin can't call it directly either.
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.campaign_outlined),
                title: const Text('Only admins can send messages'),
                subtitle: const Text('Everyone can still read and react — only sending is restricted'),
                value: group.onlyAdminsCanSend,
                onChanged: amAdmin ? (v) => GroupService.instance.setOnlyAdminsCanSend(widget.groupId, v) : null,
              ),
              // Group security settings added 2026-09-10 — same admin-only
              // pattern as the toggle above (isGroupAdmin() already covers
              // every field on this document, so no rules change needed).
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.download_outlined),
                title: const Text('Auto-download media'),
                subtitle: Text(
                  group.mediaAutoDownload
                      ? 'Photos and videos download automatically'
                      : 'Off — members tap to download each photo/video',
                ),
                value: group.mediaAutoDownload,
                onChanged: amAdmin ? (v) => GroupService.instance.setMediaAutoDownload(widget.groupId, v) : null,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.done_all),
                title: const Text('Read receipts'),
                subtitle: Text(group.readReceiptsEnabled ? '"Seen by" is tracked for this group' : 'Off for everyone in this group'),
                value: group.readReceiptsEnabled,
                onChanged: amAdmin ? (v) => GroupService.instance.setReadReceiptsEnabled(widget.groupId, v) : null,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: const Text('Hide member list'),
                subtitle: Text(group.hideMemberListFromNonAdmins ? 'Only admins can see the full member list' : 'Everyone can see who\'s in this group'),
                value: group.hideMemberListFromNonAdmins,
                onChanged: amAdmin ? (v) => GroupService.instance.setHideMemberListFromNonAdmins(widget.groupId, v) : null,
              ),
              // Feature: "clear on exit" ephemeral view mode, group
              // version. Admin-only (isGroupAdmin() already covers every
              // field on this document — no rules change needed). Turning
              // it on doesn't clear anything by itself; each member's
              // device only wipes its own local copy the next time THEIR
              // OWN GroupChatScreen closes — see GroupChatScreen.dispose().
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.timer_off_outlined),
                title: const Text('Clear on exit'),
                subtitle: Text(
                  group.ephemeralViewEnabled
                      ? "On — leaving this group wipes it from that member's own device only, even right after messages come in"
                      : amAdmin
                          ? 'Each member\'s device clears its own local copy of this group every time they leave it'
                          : 'Off — only a group admin can turn this on',
                ),
                value: group.ephemeralViewEnabled,
                onChanged: amAdmin ? (v) => GroupService.instance.setEphemeralViewEnabled(widget.groupId, v) : null,
              ),
              ListTile(
                leading: const Icon(Icons.perm_media_outlined),
                title: const Text('Media, links and voice messages'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatMediaBrowserScreen(conversationId: widget.groupId, title: group.name)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.wallpaper_outlined),
                title: const Text('Chat wallpaper'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatWallpaperScreen(conversationId: widget.groupId)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Muted keywords for this group'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => KeywordMuteScreen(conversationId: widget.groupId)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.auto_delete_outlined),
                title: const Text('Auto-wipe if inactive'),
                subtitle: Text(_inactivityOverrideLabel()),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickInactivityOverride,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.notifications_off_outlined),
                title: const Text('Mute notifications'),
                subtitle: const Text('Turn off alerts for this group only'),
                value: GroupService.instance.isMutedByMe(snapshot.data!.data() ?? {}),
                onChanged: (v) => GroupService.instance.setMuted(widget.groupId, v),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.archive_outlined),
                title: const Text('Archive group'),
                subtitle: const Text('Hide from your main chat list — new messages still arrive normally'),
                value: GroupService.instance.isArchivedByMe(snapshot.data!.data() ?? {}),
                onChanged: (v) => GroupService.instance.setArchived(widget.groupId, v),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Members', style: Theme.of(context).textTheme.titleSmall),
                    if (amAdmin)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: () => _addMembers(group),
                            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                            label: const Text('Add'),
                          ),
                          TextButton.icon(
                            onPressed: () => _inviteNonContact(group),
                            icon: const Icon(Icons.mail_outline, size: 18),
                            label: const Text('Invite'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              // Group security setting: hide member list. Members can
              // still see THEMSELVES and the overall count (shown up top)
              // — just not who else is in the group. Admins always see
              // the full list regardless, since they need it to do
              // anything member-related at all.
              if (!amAdmin && group.hideMemberListFromNonAdmins)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(
                    'The member list is hidden by this group\'s admins.',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                  ),
                )
              else
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
                      trailing: uid == _myUid
                          ? null
                          : PopupMenuButton<String>(
                              onSelected: (action) {
                                switch (action) {
                                  case 'verify':
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SafetyNumberScreen(peerUid: uid, peerUsername: username),
                                      ),
                                    );
                                    break;
                                  case 'promote':
                                    GroupService.instance.promoteAdmin(widget.groupId, uid);
                                    break;
                                  case 'demote':
                                    GroupService.instance.demoteAdmin(widget.groupId, uid);
                                    break;
                                  case 'remove':
                                    _removeMember(uid, username);
                                    break;
                                  case 'transfer_owner':
                                    _confirmTransferOwnership(uid, username);
                                    break;
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(value: 'verify', child: Text('Verify safety number')),
                                if (amAdmin && !isAdminRow) const PopupMenuItem(value: 'promote', child: Text('Make admin')),
                                if (amAdmin && isAdminRow && !isOwnerRow) const PopupMenuItem(value: 'demote', child: Text('Remove as admin')),
                                if (amAdmin && !isOwnerRow) const PopupMenuItem(value: 'remove', child: Text('Remove from group')),
                                if (group.isOwner(_myUid) && !isOwnerRow) const PopupMenuItem(value: 'transfer_owner', child: Text('Make group owner')),
                              ],
                            ),
                    );
                  },
                ),
              const Divider(),
              ListTile(
                leading: Icon(Icons.flag_outlined, color: scheme.error),
                title: Text('Report this group', style: TextStyle(color: scheme.error)),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ReportGroupScreen(groupId: widget.groupId, groupName: group.name)),
                ),
              ),
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
