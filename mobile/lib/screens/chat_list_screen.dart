import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/local_message.dart';
import '../services/auth_service.dart';
import '../services/local_message_store.dart';
import 'chat/chat_detail_screen.dart';
import 'contacts/contacts_screen.dart';
import 'contacts/find_users_screen.dart';
import 'settings/settings_screen.dart';

/// A row shown on the home screen — either a real ConversationSummary (has
/// at least one local message) or a placeholder for a conversation you've
/// opened but haven't sent anything in yet.
class _ChatRow {
  final String conversationId;
  final String peerUid;
  final String lastText;
  final DateTime lastAt;
  final int unreadCount;
  final bool isPlaceholder;

  _ChatRow({
    required this.conversationId,
    required this.peerUid,
    required this.lastText,
    required this.lastAt,
    required this.unreadCount,
    required this.isPlaceholder,
  });
}

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final Map<String, String> _usernameCache = {};

  List<ConversationSummary> _localSummaries = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _convoDocs = [];
  bool _localLoaded = false;
  bool _convoLoaded = false;

  late final StreamSubscription _localSub;
  late final StreamSubscription _convoSub;

  @override
  void initState() {
    super.initState();
    _localSub = LocalMessageStore.watchSummaries().listen((list) {
      if (!mounted) return;
      setState(() {
        _localSummaries = list;
        _localLoaded = true;
      });
    });

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    _convoSub = FirebaseFirestore.instance
        .collection('conversations')
        .where('participants', arrayContains: myUid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _convoDocs = snap.docs;
        _convoLoaded = true;
      });
    });

    // Show a one-time welcome / welcome-back message set by AuthService
    // right after sign-in or sign-up.
    final welcome = AuthService.pendingWelcomeMessage;
    if (welcome != null) {
      AuthService.pendingWelcomeMessage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(welcome), duration: const Duration(seconds: 4)),
        );
      });
    }
  }

  @override
  void dispose() {
    _localSub.cancel();
    _convoSub.cancel();
    super.dispose();
  }

  Future<String> _usernameFor(String uid) async {
    if (_usernameCache.containsKey(uid)) return _usernameCache[uid]!;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final name = (doc.data()?['username'] as String?) ?? 'Unknown';
    _usernameCache[uid] = name;
    return name;
  }

  /// Merges real message-backed summaries with any conversation you've
  /// opened but not messaged in yet, so a chat shows up on the home screen
  /// the moment you start it — not only after the first message is sent.
  List<_ChatRow> _mergedRows(String myUid) {
    final byConvo = <String, _ChatRow>{};
    for (final s in _localSummaries) {
      byConvo[s.conversationId] = _ChatRow(
        conversationId: s.conversationId,
        peerUid: s.peerUid,
        lastText: s.lastText,
        lastAt: s.lastAt,
        unreadCount: s.unreadCount,
        isPlaceholder: false,
      );
    }
    for (final doc in _convoDocs) {
      if (byConvo.containsKey(doc.id)) continue;
      final participants = List<String>.from(doc.data()['participants'] ?? []);
      final peerUid = participants.firstWhere((p) => p != myUid, orElse: () => '');
      if (peerUid.isEmpty) continue;
      final createdAt = (doc.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      byConvo[doc.id] = _ChatRow(
        conversationId: doc.id,
        peerUid: peerUid,
        lastText: 'Say hi 👋',
        lastAt: createdAt,
        unreadCount: 0,
        isPlaceholder: true,
      );
    }
    final rows = byConvo.values.toList()..sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search people',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FindUsersScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (myUid == null || !_localLoaded || !_convoLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = _mergedRows(myUid);
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 72, color: scheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 16),
                    Text('No conversations yet', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the button below to message a contact.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final row = rows[i];
              return FutureBuilder<String>(
                future: _usernameFor(row.peerUid),
                builder: (context, nameSnap) {
                  final username = nameSnap.data ?? '…';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
                    ),
                    title: Text(username),
                    subtitle: Text(
                      row.lastText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: row.isPlaceholder ? TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic) : null,
                    ),
                    trailing: row.unreadCount > 0
                        ? CircleAvatar(
                            radius: 11,
                            backgroundColor: scheme.primary,
                            child: Text(
                              '${row.unreadCount}',
                              style: TextStyle(fontSize: 11, color: scheme.onPrimary, fontWeight: FontWeight.w700),
                            ),
                          )
                        : null,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatDetailScreen(
                          conversationId: row.conversationId,
                          peerUid: row.peerUid,
                          peerUsername: username,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ContactsScreen()),
        ),
        child: const Icon(Icons.chat_rounded),
      ),
    );
  }
}
