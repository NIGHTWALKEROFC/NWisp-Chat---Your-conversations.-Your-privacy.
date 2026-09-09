import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/conversation_service.dart';
import '../../services/app_lock_service.dart';
import '../../services/chat_freeze_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/moderation_service.dart';
import '../report_user_screen.dart';
import '../security/safety_number_screen.dart';

const _chatTtlOptions = [0, 1, 6, 24, 72, 168]; // 0 = never for THIS chat specifically, hours after that

class ChatSettingsScreen extends StatefulWidget {
  final String conversationId;
  final String peerUid;
  final String peerUsername;

  const ChatSettingsScreen({
    super.key,
    required this.conversationId,
    required this.peerUid,
    required this.peerUsername,
  });

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  final _conversationService = ConversationService();
  final _moderationService = ModerationService();
  bool _clearing = false;
  bool _hideLocked = true; // chat hiding not set up at all, until proven otherwise
  bool _hidden = false;
  bool _appLockNotSetUp = true; // App Lock (PIN) not set up at all, until proven otherwise
  bool _chatLocked = false;
  bool _hideNameInNotifications = false;

  @override
  void initState() {
    super.initState();
    _loadHideState();
    _loadChatLockState();
    _loadNotificationPrivacyState();
  }

  Future<void> _loadNotificationPrivacyState() async {
    final enabled = await _moderationService.isNotificationPrivacyEnabled(widget.peerUid);
    if (!mounted) return;
    setState(() => _hideNameInNotifications = enabled);
  }

  Future<void> _toggleNotificationPrivacy(bool value) async {
    await _moderationService.setNotificationPrivacy(widget.peerUid, value);
    if (!mounted) return;
    setState(() => _hideNameInNotifications = value);
  }

  Future<void> _loadHideState() async {
    final setUp = await ChatLockService.isSetUp();
    final hidden = await ChatLockService.isHidden(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _hideLocked = !setUp;
      _hidden = hidden;
    });
  }

  Future<void> _loadChatLockState() async {
    final appLockOn = await AppLockService.isEnabled();
    final locked = await ChatLockService.isLocked(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _appLockNotSetUp = !appLockOn;
      _chatLocked = locked;
    });
  }

  Future<void> _toggleChatLocked(bool value) async {
    await ChatLockService.setLocked(widget.conversationId, value);
    if (!mounted) return;
    setState(() => _chatLocked = value);
  }

  Future<void> _pauseChat() async {
    final choice = await showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Pause this chat for…', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(title: const Text('1 hour'), onTap: () => Navigator.pop(sheetContext, const Duration(hours: 1))),
            ListTile(title: const Text('1 day'), onTap: () => Navigator.pop(sheetContext, const Duration(days: 1))),
            ListTile(title: const Text('1 week'), onTap: () => Navigator.pop(sheetContext, const Duration(days: 7))),
            ListTile(
              title: const Text('Custom'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final picked = await _pickCustomDuration();
                if (picked != null) await _confirmAndFreeze(picked);
              },
            ),
          ],
        ),
      ),
    );
    if (choice != null) await _confirmAndFreeze(choice);
  }

  Future<Duration?> _pickCustomDuration() async {
    final days = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController(text: '3');
        return AlertDialog(
          title: const Text('Pause for how many days?'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Days'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, int.tryParse(controller.text.trim())),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
    if (days == null || days <= 0) return null;
    return Duration(days: days);
  }

  Future<void> _confirmAndFreeze(Duration duration) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pause this chat?'),
        content: Text(
          "Neither of you will be able to see this conversation or message each other for ${_describeDuration(duration)}. "
          'Either of you can end it early from Paused chats in Settings.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Pause')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChatFreezeService.instance.freeze(otherUid: widget.peerUid, duration: duration);
    if (!mounted) return;
    // Both sides lose access immediately — nothing left to do here but
    // leave, the same way hiding a chat also backs out of it.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  String _describeDuration(Duration d) {
    if (d.inDays >= 7 && d.inDays % 7 == 0) return '${d.inDays ~/ 7} week${d.inDays ~/ 7 == 1 ? '' : 's'}';
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
    return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
  }

  Future<void> _toggleHidden(bool value) async {
    await ChatLockService.setHidden(widget.conversationId, value);
    if (!mounted) return;
    setState(() => _hidden = value);
    if (value && mounted) {
      // Hiding a chat you're currently looking at needs to actually take
      // you out of it — otherwise it'd be "hidden" from the list but
      // still sitting open right in front of you.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  String _ttlLabel(int? hours) {
    if (hours == null) return 'Use app default';
    if (hours == 0) return 'Never (this chat only)';
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  void _openTtlPicker(int? current) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Auto-delete for this chat', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            RadioListTile<int?>(
              value: null,
              groupValue: current,
              title: const Text('Use app default'),
              subtitle: const Text('Follows your Settings > Auto-delete messages value'),
              onChanged: (value) async {
                await _conversationService.setChatTtlHours(widget.conversationId, null);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
            for (final hours in _chatTtlOptions)
              RadioListTile<int?>(
                value: hours,
                groupValue: current,
                title: Text(_ttlLabel(hours)),
                onChanged: (value) async {
                  await _conversationService.setChatTtlHours(widget.conversationId, hours);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear this chat?'),
        content: Text(
          'This deletes every message in this chat for both you and @${widget.peerUsername}. '
          'This can\'t be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear chat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearing = true);
    try {
      await MessageRelayService.clearForBoth(conversationId: widget.conversationId, toUid: widget.peerUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat cleared')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not clear chat')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _confirmBlock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Block ${widget.peerUsername}?'),
        content: const Text('They will no longer be able to message you.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _moderationService.blockUser(widget.peerUid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${widget.peerUsername} blocked')));
  }

  Future<void> _unblock() async {
    await _moderationService.unblockUser(widget.peerUid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${widget.peerUsername} unblocked')));
  }

  Future<void> _report() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReportUserScreen(reportedUid: widget.peerUid, reportedLabel: widget.peerUsername),
      ),
    );
    if (submitted != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat settings')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _conversationService.conversationStream(widget.conversationId),
        builder: (context, snapshot) {
          final data = snapshot.data?.data() ?? {};
          final muted = _conversationService.isMutedByMe(data);
          final archived = _conversationService.isArchivedByMe(data);
          final chatTtl = (data['chatTtlHours'] as num?)?.toInt();

          return ListView(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(widget.peerUsername.isNotEmpty ? widget.peerUsername[0].toUpperCase() : '?'),
                ),
                title: Text(widget.peerUsername, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Verify safety number'),
                subtitle: const Text("Confirm you're really talking to this person"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SafetyNumberScreen(peerUid: widget.peerUid, peerUsername: widget.peerUsername),
                  ),
                ),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.notifications_off_outlined),
                title: const Text('Mute notifications'),
                subtitle: const Text('Turn off alerts for this chat only'),
                value: muted,
                onChanged: (v) => _conversationService.setMuted(widget.conversationId, v),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.archive_outlined),
                title: const Text('Archive chat'),
                subtitle: const Text('Hide from your main chat list — new messages still arrive normally'),
                value: archived,
                onChanged: (v) => _conversationService.setArchived(widget.conversationId, v),
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: const Text('Hide this chat'),
                subtitle: Text(
                  _hideLocked
                      ? 'Set up chat hiding in Settings > Chat hiding first'
                      : 'Removed from your chat list entirely — type your code into search to bring it back',
                ),
                value: _hidden,
                onChanged: _hideLocked ? null : _toggleHidden,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.lock_outline),
                title: const Text('Lock this chat'),
                subtitle: Text(
                  _appLockNotSetUp
                      ? 'Set up App lock (PIN) in Settings first'
                      : 'Stays visible in your chat list, but needs your PIN to open — even if App lock itself is unlocked',
                ),
                value: _chatLocked,
                onChanged: _appLockNotSetUp ? null : _toggleChatLocked,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.notifications_off_outlined),
                title: const Text('Hide name in notifications'),
                subtitle: Text(
                  'Notifications from ${widget.peerUsername} show as "New message" instead of their name — '
                  'message content never shows either way',
                ),
                value: _hideNameInNotifications,
                onChanged: _toggleNotificationPrivacy,
              ),
              ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: const Text('Pause this chat'),
                subtitle: const Text(
                  "Hide this chat and stop messages both ways for a set time — either of you can end it early",
                ),
                onTap: _pauseChat,
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Auto-delete messages'),
                subtitle: Text(_ttlLabel(chatTtl)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openTtlPicker(chatTtl),
              ),
              ListTile(
                leading: Icon(Icons.delete_sweep_outlined, color: scheme.error),
                title: Text('Clear chat', style: TextStyle(color: scheme.error)),
                subtitle: const Text('Deletes all messages in this chat, on both devices'),
                trailing: _clearing
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: _clearing ? null : _confirmClearChat,
              ),
              const Divider(height: 24),
              // Block/Unblock now reflects and toggles actual state — it
              // used to always just show "Block", even if you'd already
              // blocked this person.
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _moderationService.myProfileStream(),
                builder: (context, profileSnapshot) {
                  final blocked = List<String>.from(profileSnapshot.data?.data()?['blockedUsers'] ?? []);
                  final isBlocked = blocked.contains(widget.peerUid);
                  return ListTile(
                    leading: Icon(isBlocked ? Icons.block_flipped : Icons.block, color: scheme.error),
                    title: Text(
                      isBlocked ? 'Unblock ${widget.peerUsername}' : 'Block ${widget.peerUsername}',
                      style: TextStyle(color: scheme.error),
                    ),
                    onTap: isBlocked ? _unblock : _confirmBlock,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text('Report ${widget.peerUsername}'),
                onTap: _report,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
