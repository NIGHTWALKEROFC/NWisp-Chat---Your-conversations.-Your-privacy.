import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/private_keyboard_service.dart';
import '../../services/auth_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../chat/chat_detail_screen.dart';
import '../security/chat_pin_guard.dart';
import '../security/hidden_chat_pin_screen.dart';

class FindUsersScreen extends StatefulWidget {
  const FindUsersScreen({super.key});
  @override
  State<FindUsersScreen> createState() => _FindUsersScreenState();
}

class _FindUsersScreenState extends State<FindUsersScreen> {
  final _contactService = ContactService();
  final _authService = AuthService();
  final _conversationService = ConversationService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _results = [];

  Set<String> _contactUids = {};
  Set<String> _pendingUids = {};
  final Set<String> _sendingTo = {};
  bool _loading = false;
  bool _searched = false;
  String? _error;
  Timer? _debounce;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.length < 2) {
      setState(() {
        _results = [];
        _loading = false;
        _searched = false;
        _error = null;
      });
      return;
    }
    // Feature: chat hiding. This search field deliberately doubles as
    // the (unlabeled, on purpose) unlock spot for hidden chats — see
    // ChatLockService and ChatListScreen's search IconButton. Checked
    // before the debounce timer below so a correct code never triggers
    // a visible "no users found" flash first. The result now says WHICH
    // code matched — the common one (reveal every common-hidden chat) or
    // one specific chat's own custom code (reveal only that chat) — see
    // ChatUnlockResult.
    ChatLockService.verifyAny(trimmed).then((result) => _handleUnlock(result));
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(trimmed));
  }

  Future<void> _handleUnlock(ChatUnlockResult? result) async {
    if (result == null || !mounted) return;
    // Optional second factor: if a separate hidden-chats PIN is turned on
    // (see ChatLockSetupScreen), the correct code alone isn't enough —
    // this must also be confirmed before anything is actually revealed.
    if (await ChatLockService.isPinEnabled()) {
      if (!mounted) return;
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const HiddenChatPinScreen(mode: HiddenChatPinScreenMode.verify)),
      );
      if (ok != true || !mounted) return;
    }
    if (!mounted) return;
    Navigator.pop(context, result.isCommon ? 'unlock_common' : 'unlock_custom:${result.conversationId}');
  }

  Future<void> _search(String query) async {
    final myRequestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await _contactService.searchUsers(query);
      final contactUids = await _contactService.myContactUids();
      final pendingUids = await _contactService.myPendingOutgoingUids();
      if (!mounted || myRequestId != _requestId) return;
      setState(() {
        _results = results;
        _contactUids = contactUids;
        _pendingUids = pendingUids;
        _loading = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || myRequestId != _requestId) return;
      setState(() {
        _loading = false;
        _searched = true;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _sendRequest(String uid, String username) async {
    setState(() => _sendingTo.add(uid));
    try {
      final myProfile = await _authService.currentUserProfile();
      final myUsername = (myProfile.data()?['username'] as String?) ?? '';
      await _contactService.sendRequest(toUid: uid, toUsername: username, myUsername: myUsername);
      if (!mounted) return;
      setState(() {
        _pendingUids.add(uid);
        _sendingTo.remove(uid);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingTo.remove(uid));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _openChat(String uid, String username) async {
    try {
      final myUid = FirebaseAuth.instance.currentUser!.uid;
      final conversationId = _conversationService.conversationIdFor(myUid, uid);
      await _conversationService.ensureConversation(otherUid: uid);
      if (!mounted) return;
      // BUGFIX: see chat_pin_guard.dart's canOpenChat doc comment — a
      // search result was another way to reach an already-hidden or
      // paused chat directly, bypassing both features.
      if (!await canOpenChat(context, conversationId: conversationId, otherUid: uid)) return;
      if (!mounted) return;
      Navigator.push(
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          // Feature: private keyboard mode (off by default).
          enableSuggestions: !PrivateKeyboardService.enabled.value,
          autocorrect: !PrivateKeyboardService.enabled.value,
          enableIMEPersonalizedLearning: !PrivateKeyboardService.enabled.value,
          controller: _searchController,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search by username',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (value) {
            _debounce?.cancel();
            if (value.trim().length >= 2) _search(value.trim());
          },
        ),
      ),
      body: Builder(
        builder: (context) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: scheme.error),
                    const SizedBox(height: 12),
                    Text('Search failed', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        final q = _searchController.text.trim();
                        if (q.length >= 2) _search(q);
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!_searched) {
            return Center(
              child: Text('Type at least 2 characters to search', style: TextStyle(color: scheme.onSurfaceVariant)),
            );
          }
          if (_results.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_off, size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text('No users found for "${_searchController.text.trim()}"',
                        textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final user = _results[i];
              final uid = user['uid'] as String;
              final username = (user['username'] as String?) ?? '';
              final isContact = _contactUids.contains(uid);
              final isPending = _pendingUids.contains(uid);
              final isSending = _sendingTo.contains(uid);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                ),
                title: Text(username),
                onTap: isContact ? () => _openChat(uid, username) : null,
                trailing: isContact
                    ? TextButton.icon(
                        onPressed: () => _openChat(uid, username),
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        label: const Text('Message'),
                      )
                    : isPending
                        ? const Text('Requested')
                        : TextButton(
                            onPressed: isSending ? null : () => _sendRequest(uid, username),
                            child: isSending
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Add'),
                          ),
              );
            },
          );
        },
      ),
    );
  }
}
