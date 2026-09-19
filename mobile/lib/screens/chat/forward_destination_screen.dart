import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/contact_service.dart';
import '../../services/conversation_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/signal_session_service.dart';

/// Feature: permission-gated message forwarding — the "who do you want to
/// send this to?" step.
///
/// Only ever opened by ChatDetailScreen AFTER it has seen that forwarding is
/// switched on for the source chat. MessageRelayService.forwardTextMessage
/// checks that permission again, live from the server, at the moment of
/// sending — so if the other person switches forwarding off while this
/// screen is open, the send is refused rather than going through.
///
/// Scope of this first version: one text message, forwarded into one of your
/// 1:1 contacts' chats. Pops with the recipient's username on success.
class ForwardDestinationScreen extends StatefulWidget {
  final String sourceConversationId;
  final String sourcePeerUid;
  final String text;

  const ForwardDestinationScreen({
    super.key,
    required this.sourceConversationId,
    required this.sourcePeerUid,
    required this.text,
  });

  @override
  State<ForwardDestinationScreen> createState() => _ForwardDestinationScreenState();
}

class _ForwardDestinationScreenState extends State<ForwardDestinationScreen> {
  final _contactService = ContactService();
  final _conversationService = ConversationService();
  final _searchController = TextEditingController();

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  Set<String> _hiddenConversationIds = {};
  Set<String> _blockedUids = {};
  bool _loadedFilters = false;
  String? _sendingUid;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadFilters();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Two things must never show up in this list: chats the person has hidden
  /// (listing them here would give away that they exist) and people they've
  /// blocked.
  Future<void> _loadFilters() async {
    Set<String> hidden = {};
    Set<String> blocked = {};
    try {
      hidden = await ChatLockService.getAllHiddenIds();
    } catch (_) {}
    try {
      final profile = await AuthService().currentUserPrivateProfile();
      blocked = List<String>.from(profile.data()?['blockedUsers'] ?? const []).toSet();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _hiddenConversationIds = hidden;
      _blockedUids = blocked;
      _loadedFilters = true;
    });
  }

  /// The same "chat's own setting, else my profile default, else never"
  /// rule ChatDetailScreen uses for its own sends, applied to the
  /// DESTINATION chat so a forwarded message disappears on the same
  /// schedule as everything else in that chat.
  Future<int> _effectiveTtlHoursFor(String destConversationId) async {
    int? chatTtl;
    int? profileTtl;
    try {
      final convo = await FirebaseFirestore.instance.collection('conversations').doc(destConversationId).get();
      chatTtl = (convo.data()?['chatTtlHours'] as num?)?.toInt();
    } catch (_) {}
    try {
      final profile = await AuthService().currentUserPrivateProfile();
      profileTtl = (profile.data()?['messageTtlHours'] as num?)?.toInt();
    } catch (_) {}
    return chatTtl ?? profileTtl ?? 0;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
  }

  Future<bool> _confirmIdentityChangeAndRetry(String uid, String username) async {
    final trust = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Security code changed'),
        content: Text(
          "$username's encryption keys have changed since you last talked. "
          "This usually just means they reinstalled the app or got a new device — but it's "
          'also what it would look like if something were wrong. Send anyway?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Trust & send')),
        ],
      ),
    );
    if (trust != true) return false;
    try {
      await SignalSessionService.instance.acceptChangedIdentityAndRetry(uid);
      return true;
    } catch (_) {
      _showSnack("Couldn't confirm the new key — please try again.");
      return false;
    }
  }

  Future<void> _forwardTo(String uid, String username) async {
    if (_sendingUid != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forward to $username?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(widget.text, maxLines: 6, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 10),
            Text(
              'It will be marked "Forwarded" and stays end-to-end encrypted.',
              style: TextStyle(fontSize: 12.5, color: Theme.of(dialogContext).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Forward')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sendingUid = uid);
    try {
      final destConversationId = _conversationService.conversationIdFor(_myUid, uid);
      await _conversationService.ensureConversation(otherUid: uid);
      final ttl = await _effectiveTtlHoursFor(destConversationId);

      Future<void> attempt() => MessageRelayService.forwardTextMessage(
            sourceConversationId: widget.sourceConversationId,
            destConversationId: destConversationId,
            destPeerUid: uid,
            text: widget.text,
            ttlHours: ttl,
          );

      try {
        await attempt();
      } on IdentityChangedException catch (_) {
        if (!mounted) return;
        final trusted = await _confirmIdentityChangeAndRetry(uid, username);
        if (!trusted) return;
        await attempt();
      }
      if (!mounted) return;
      Navigator.pop(context, username);
    } on ForwardingRestrictedException catch (e) {
      // Permission went away (or couldn't be confirmed) — nothing was sent.
      _showSnack(e.message);
      if (mounted) Navigator.pop(context);
    } on BlockedException catch (e) {
      _showSnack(e.message);
    } on ChatFrozenException catch (e) {
      _showSnack(e.message);
    } on RateLimitedException catch (e) {
      _showSnack(e.message);
    } on NotSignedInException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Not forwarded — $e');
    } finally {
      if (mounted) setState(() => _sendingUid = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Forward to…')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.forward, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.text, maxLines: 3, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search contacts'),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: !_loadedFilters
                ? const Center(child: CircularProgressIndicator())
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _contactService.contactsStream(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(child: Text('Could not load contacts', style: TextStyle(color: scheme.error)));
                      }
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                      final entries = snapshot.data!.docs.where((d) {
                        final uid = d.id;
                        if (uid == _myUid || uid == widget.sourcePeerUid) return false;
                        if (_blockedUids.contains(uid)) return false;
                        if (_hiddenConversationIds.contains(_conversationService.conversationIdFor(_myUid, uid))) return false;
                        final name = ((d.data()['username'] as String?) ?? '').toLowerCase();
                        return _query.isEmpty || name.contains(_query);
                      }).toList();
                      if (entries.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              _query.isEmpty ? 'No other contacts to forward to yet.' : 'No contacts match "$_query".',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final doc = entries[i];
                          final username = (doc.data()['username'] as String?) ?? 'Unknown';
                          final sendingThis = _sendingUid == doc.id;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: scheme.primaryContainer,
                              child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                            ),
                            title: Text(username),
                            trailing: sendingThis
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.send_outlined),
                            enabled: _sendingUid == null || sendingThis,
                            onTap: () => _forwardTo(doc.id, username),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
