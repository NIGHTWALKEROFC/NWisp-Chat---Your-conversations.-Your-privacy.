import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/nickname_service.dart';
import '../../widgets/nickname_dialog.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../../widgets/user_avatar.dart';
import '../chat/chat_detail_screen.dart';
import '../groups/create_group_screen.dart';
import '../security/chat_pin_guard.dart';
import 'find_users_screen.dart';
import 'qr_code_screen.dart';

class ContactsScreen extends StatefulWidget {
  /// 0 = Contacts, 1 = Requests, 2 = Discover.
  final int initialTab;
  const ContactsScreen({super.key, this.initialTab = 0});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with SingleTickerProviderStateMixin {
  final _contactService = ContactService();
  final _conversationService = ConversationService();
  late final TabController _tabController = TabController(length: 3, vsync: this, initialIndex: widget.initialTab.clamp(0, 2));

  String? _openingUid;

  @override
  void initState() {
    super.initState();
    NicknameService.instance.load();
  }

  // Long-press-to-multi-select, WhatsApp style: long-press a contact to
  // start selecting more, then tap the checkmark to create a group from
  // exactly those people.
  bool _selectionMode = false;
  final Set<String> _selectedUids = {};

  void _startSelection(String uid) {
    setState(() {
      _selectionMode = true;
      _selectedUids.add(uid);
    });
  }

  void _toggleSelection(String uid) {
    setState(() {
      if (_selectedUids.contains(uid)) {
        _selectedUids.remove(uid);
        if (_selectedUids.isEmpty) _selectionMode = false;
      } else {
        _selectedUids.add(uid);
      }
    });
  }

  void _cancelSelection() {
    setState(() {
      _selectionMode = false;
      _selectedUids.clear();
    });
  }

  Future<void> _goCreateGroup() async {
    final selected = Set<String>.from(_selectedUids);
    _cancelSelection();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CreateGroupScreen(initialSelectedUids: selected)),
    );
  }

  Future<void> _openChat(String uid, String username) async {
    if (_openingUid != null) return;
    setState(() => _openingUid = uid);
    try {
      final myUid = FirebaseAuth.instance.currentUser!.uid;
      final conversationId = _conversationService.conversationIdFor(myUid, uid);
      await _conversationService.ensureConversation(otherUid: uid);
      if (!mounted) return;
      // BUGFIX: tapping a contact used to open ChatDetailScreen directly
      // with no check at all — a real way around both hiding and pausing,
      // since this reaches the exact same conversationId either feature
      // already applies to. See chat_pin_guard.dart's canOpenChat.
      if (!await canOpenChat(context, conversationId: conversationId, otherUid: uid)) return;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailScreen(conversationId: conversationId, peerUid: uid, peerUsername: username),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open this chat. Check your connection and try again.")),
      );
    } finally {
      if (mounted) setState(() => _openingUid = null);
    }
  }

  Widget _errorState(BuildContext context, Object? error) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text('Could not load this', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('$error', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(icon: const Icon(Icons.close), onPressed: _cancelSelection)
            : null,
        title: _selectionMode ? Text('${_selectedUids.length} selected') : const Text('Contacts'),
        bottom: _selectionMode
            ? null
            : TabBar(
                controller: _tabController,
                tabs: [
                  const Tab(text: 'Contacts'),
                  // Feature: count badge so new requests can't be missed.
                  Tab(
                    child: StreamBuilder<int>(
                      stream: _contactService.pendingRequestCountStream(),
                      builder: (context, snap) {
                        final count = snap.data ?? 0;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Requests'),
                            if (count > 0) ...[
                              const SizedBox(width: 6),
                              Badge(label: Text(count > 99 ? '99+' : '$count')),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  const Tab(text: 'Discover'),
                ],
              ),
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.groups_rounded),
                  tooltip: 'Create group',
                  onPressed: _selectedUids.length >= 2 ? _goCreateGroup : null,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  tooltip: 'Add via QR code',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const QrCodeScreen()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  tooltip: 'Find people',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FindUsersScreen()),
                  ),
                ),
              ],
      ),
      body: TabBarView(
        controller: _tabController,
        physics: _selectionMode ? const NeverScrollableScrollPhysics() : null,
        children: [
          StreamBuilder(
            stream: _contactService.contactsStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return _errorState(context, snapshot.error);
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline, size: 64, color: scheme.primary.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        const Text('No contacts yet'),
                        const SizedBox(height: 4),
                        Text('Tap the add-person icon to find people by username.',
                            textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final uid = docs[i].id;
                  final data = docs[i].data();
                  final storedName = ((data['username'] as String?) ?? '').trim();
                  final username = storedName.isEmpty ? 'Unknown' : storedName;
                  final isOpening = _openingUid == uid;
                  final isSelected = _selectedUids.contains(uid);
                  return ListTile(
                    leading: Stack(
                      children: [
                        UserAvatar(uid: uid, name: username),
                        if (_selectionMode && isSelected)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              padding: const EdgeInsets.all(1.5),
                              decoration: BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
                              child: CircleAvatar(radius: 9, backgroundColor: scheme.primary, child: const Icon(Icons.check, size: 12, color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                    title: ValueListenableBuilder<int>(
                      valueListenable: NicknameService.instance.changes,
                      builder: (_, __, ___) {
                        final nick = NicknameService.instance.nicknameFor(uid);
                        if (nick != null) return Text(nick);
                        return storedName.isEmpty
                            ? FutureBuilder<String>(
                                future: _contactService.usernameFor(uid),
                                builder: (_, s) => Text(s.data ?? 'Unknown'),
                              )
                            : Text(username);
                      },
                    ),
                    subtitle: NicknameService.instance.nicknameFor(uid) != null ? Text('@$username') : null,
                    trailing: _selectionMode
                        ? null
                        : (isOpening
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (value) {
                                  if (value == 'message') _openChat(uid, username);
                                  if (value == 'remove') _confirmRemove(uid, username);
                                  if (value == 'nick') showNicknameDialog(context, uid: uid, realName: username);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'message', child: Text('Message')),
                                  PopupMenuItem(value: 'nick', child: Text('Set nickname')),
                                  PopupMenuItem(value: 'remove', child: Text('Remove contact')),
                                ],
                              )),
                    selected: isSelected,
                    selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                    onTap: _selectionMode ? () => _toggleSelection(uid) : () => _openChat(uid, username),
                    onLongPress: _selectionMode ? null : () => _startSelection(uid),
                  );
                },
              );
            },
          ),
          StreamBuilder(
            stream: _contactService.incomingRequestsStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return _errorState(context, snapshot.error);
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return Center(
                  child: Text('No pending requests', style: TextStyle(color: scheme.onSurfaceVariant)),
                );
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final data = docs[i].data();
                  final fromUid = data['fromUid'] as String;
                  final fromUsername = ((data['fromUsername'] as String?) ?? '').trim();
                  return ListTile(
                    leading: UserAvatar(uid: fromUid, name: fromUsername),
                    title: fromUsername.isEmpty
                        ? FutureBuilder<String>(
                            future: _contactService.usernameFor(fromUid),
                            builder: (_, s) => Text(s.data ?? 'Unknown'),
                          )
                        : Text(fromUsername),
                    subtitle: const Text('wants to add you'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.check_circle, color: scheme.primary),
                          onPressed: () => _contactService.acceptRequest(docs[i].id, fromUid, fromUsername),
                        ),
                        IconButton(
                          icon: Icon(Icons.cancel_outlined, color: scheme.error),
                          onPressed: () => _contactService.declineRequest(docs[i].id),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const _DiscoverTab(),
        ],
      ),
    );
  }

  /// Feature: unfriend.
  Future<void> _confirmRemove(String uid, String username) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $username?'),
        content: const Text(
          "They'll be removed from your contacts and you'll be removed from theirs. "
          "They won't be notified, and your existing chat stays as it is. You can add each other again any time.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _contactService.removeContact(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$username removed from your contacts')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't remove — check your connection and try again.")));
    }
  }
}

/// Feature: "People on NWisp" — people who chose to be shown in suggestions.
/// The switch at the top is the same setting as Settings → Privacy.
class _DiscoverTab extends StatefulWidget {
  const _DiscoverTab();

  @override
  State<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<_DiscoverTab> with AutomaticKeepAliveClientMixin {
  final _contacts = ContactService();
  final _auth = AuthService();
  final _search = TextEditingController();

  List<Map<String, dynamic>> _people = [];
  final Set<String> _requested = {};
  final Set<String> _sending = {};
  bool _loading = true;
  bool _visible = false;
  bool _savingVisible = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final visible = await _auth.isDiscoverable();
      final people = await _contacts.discoverUsers();
      if (!mounted) return;
      setState(() {
        _visible = visible;
        _people = people;
        _requested
          ..clear()
          ..addAll(people.where((p) => p['pending'] == true).map((p) => p['uid'] as String));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load people. Check your connection and pull down to try again.";
      });
    }
  }

  Future<void> _setVisible(bool value) async {
    setState(() {
      _visible = value;
      _savingVisible = true;
    });
    try {
      await _auth.setDiscoverable(value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _visible = !value);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save that — try again.")));
    } finally {
      if (mounted) setState(() => _savingVisible = false);
    }
  }

  Future<void> _add(String uid, String username) async {
    setState(() => _sending.add(uid));
    try {
      await _contacts.sendRequest(toUid: uid, toUsername: username, myUsername: '');
      if (!mounted) return;
      setState(() {
        _requested.add(uid);
        _sending.remove(uid);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending.remove(uid));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? _people
        : _people.where((p) => ((p['username'] as String?) ?? '').toLowerCase().contains(q)).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Show me in suggestions', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _visible
                  ? 'Other NWisp users can see your username and photo here.'
                  : "You're hidden. Turn this on to appear in other people's suggestions.",
              style: const TextStyle(fontSize: 12.5),
            ),
            value: _visible,
            onChanged: _savingVisible ? null : _setVisible,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search these people',
                isDense: true,
              ),
            ),
          ),
          if (_loading)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
            )
          else if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(Icons.people_outline, size: 56, color: scheme.primary.withValues(alpha: 0.5)),
                  const SizedBox(height: 10),
                  Text(
                    q.isEmpty ? 'Nobody to suggest yet' : 'No one matches "$q"',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'People appear here when they allow suggestions. Pull down to refresh.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else
            for (final person in shown)
              Builder(builder: (context) {
                final uid = person['uid'] as String;
                final name = ((person['username'] as String?) ?? '').trim();
                final isRequested = _requested.contains(uid);
                final isSending = _sending.contains(uid);
                return ListTile(
                  leading: UserAvatar(uid: uid, name: name),
                  title: Text(name),
                  subtitle: const Text('On NWisp'),
                  trailing: isRequested
                      ? const Text('Requested')
                      : FilledButton.tonal(
                          onPressed: isSending ? null : () => _add(uid, name),
                          child: isSending
                              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Add'),
                        ),
                );
              }),
        ],
      ),
    );
  }
}
