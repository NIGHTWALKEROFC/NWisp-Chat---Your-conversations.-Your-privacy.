import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/contact_service.dart';
import '../services/conversation_service.dart';
import '../services/group_service.dart';
import '../services/nickname_service.dart';
import '../services/share_intake_service.dart';
import '../widgets/user_avatar.dart';
import 'chat/chat_detail_screen.dart';
import 'groups/group_chat_screen.dart';
import 'security/chat_pin_guard.dart';

/// "Send to…" — opened when something is shared to NWisp from another app.
/// Pick a person or group; their chat opens with the text in the message box
/// (or the picture in the preview), ready to look over and send. Nothing is
/// sent until you press send there.
class ShareTargetScreen extends StatefulWidget {
  final SharedContent content;
  const ShareTargetScreen({super.key, required this.content});

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  final _contacts = ContactService();
  final _search = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    NicknameService.instance.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openContact(String uid, String username) async {
    final myUid = FirebaseAuth.instance.currentUser!.uid;
    final conversations = ConversationService();
    final id = conversations.conversationIdFor(myUid, uid);
    await conversations.ensureConversation(otherUid: uid);
    if (!mounted) return;
    if (!await canOpenChat(context, conversationId: id, otherUid: uid)) return;
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ChatDetailScreen(conversationId: id, peerUid: uid, peerUsername: username, share: widget.content)),
    );
  }

  Future<void> _openGroup(String groupId) async {
    if (!await requireChatPinIfLocked(context, groupId)) return;
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId, share: widget.content)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send to…'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.secondaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                if (c.files.isNotEmpty && !c.files.first.isVideo)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(c.files.first.path), width: 48, height: 48, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined)),
                  )
                else
                  Icon(c.files.isNotEmpty ? Icons.videocam_outlined : Icons.text_snippet_outlined, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Sharing ${c.summary}', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer)),
                    if (c.text != null && c.text!.trim().isNotEmpty)
                      Text(c.text!.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSecondaryContainer.withValues(alpha: 0.8), fontSize: 12.5)),
                  ]),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search people and groups',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: GroupService.instance.myGroupsStream(),
                  builder: (context, snap) {
                    final docs = (snap.data?.docs ?? const []).where((d) => (((d.data()['name'] as String?) ?? '').toLowerCase()).contains(_q)).toList();
                    if (docs.isEmpty) return const SizedBox.shrink();
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('GROUPS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6))),
                      for (final d in docs)
                        ListTile(
                          leading: CircleAvatar(backgroundColor: scheme.primaryContainer, child: const Icon(Icons.groups_rounded)),
                          title: Text((d.data()['name'] as String?) ?? 'Group'),
                          onTap: () => _openGroup(d.id),
                        ),
                    ]);
                  },
                ),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _contacts.contactsStream(),
                  builder: (context, snap) {
                    if (!snap.hasData) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
                    final docs = snap.data!.docs.where((d) {
                      final name = ((d.data()['username'] as String?) ?? '').toLowerCase();
                      final nick = (NicknameService.instance.nicknameFor(d.id) ?? '').toLowerCase();
                      return name.contains(_q) || nick.contains(_q);
                    }).toList();
                    if (docs.isEmpty) {
                      return Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No contacts found', style: TextStyle(color: scheme.onSurfaceVariant))));
                    }
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('PEOPLE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6))),
                      for (final d in docs)
                        Builder(builder: (_) {
                          final real = ((d.data()['username'] as String?) ?? '').trim();
                          final shown = NicknameService.instance.display(d.id, real.isEmpty ? 'Unknown' : real);
                          return ListTile(
                            leading: UserAvatar(uid: d.id, name: shown),
                            title: Text(shown),
                            onTap: () => _openContact(d.id, real.isEmpty ? 'Unknown' : real),
                          );
                        }),
                    ]);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
