import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/conversation_service.dart';
import '../../services/chat_freeze_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/inactivity_wipe_service.dart';
import '../../services/message_relay_service.dart';
import '../../services/moderation_service.dart';
import '../report_user_screen.dart';
import '../security/pin_screen.dart';
import '../security/safety_number_screen.dart';
import '../settings/chat_lock_setup_screen.dart';
import '../settings/keyword_mute_screen.dart';
import '../../widgets/mute_duration_sheet.dart';
import '../../widgets/user_avatar.dart';
import 'chat_media_browser_screen.dart';
import 'chat_wallpaper_screen.dart';

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
  bool _commonSetUp = false;
  bool _hiddenViaCommon = false;
  bool _hiddenViaCustom = false;
  bool _locked = false;
  // Feature: inactivity auto-wipe, per-chat override. null = no
  // override (follows the global Settings default).
  bool? _inactivityOverrideEnabled;
  int _inactivityOverrideMonths = 3;

  @override
  void initState() {
    super.initState();
    _loadHideState();
    _loadLockState();
    _loadInactivityOverride();
  }

  Future<void> _loadInactivityOverride() async {
    final override = await InactivityWipeService.getChatOverride(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _inactivityOverrideEnabled = override?.enabled;
      _inactivityOverrideMonths = override?.months ?? 3;
    });
  }

  String _inactivityOverrideLabel() {
    if (_inactivityOverrideEnabled == null) return "Follows your Settings > Auto-wipe inactive chats default";
    if (_inactivityOverrideEnabled == true) return "On for this chat — clears after $_inactivityOverrideMonths month${_inactivityOverrideMonths == 1 ? '' : 's'} of not opening it, no matter the app default";
    return "Off for this chat, even if the app default is on";
  }

  Future<void> _pickInactivityOverride() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Auto-wipe if inactive'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'default'), child: const Text('Follow app default')),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'off'), child: const Text('Off for this chat')),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialogContext, 'on'), child: const Text('On for this chat')),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'default') {
      await InactivityWipeService.clearChatOverride(widget.conversationId);
      if (mounted) setState(() => _inactivityOverrideEnabled = null);
      return;
    }
    if (choice == 'off') {
      await InactivityWipeService.setChatOverride(widget.conversationId, false, _inactivityOverrideMonths);
      if (mounted) setState(() => _inactivityOverrideEnabled = false);
      return;
    }
    // 'on' — also ask how long, same options as the global picker.
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
    await InactivityWipeService.setChatOverride(widget.conversationId, true, months);
    if (mounted) setState(() {
      _inactivityOverrideEnabled = true;
      _inactivityOverrideMonths = months;
    });
  }

  Future<void> _loadLockState() async {
    final locked = await ChatLockService.isLocked(widget.conversationId);
    if (!mounted) return;
    setState(() => _locked = locked);
  }

  /// Turning ON requires the app PIN to already be set up (this feature
  /// deliberately reuses it rather than adding a third PIN type — see
  /// chat_pin_guard.dart). Turning OFF doesn't need re-verification: you
  /// can only be looking at this screen because you already got past the
  /// PIN to open this chat in the first place.
  Future<void> _toggleLocked(bool value) async {
    if (value && !await AppLockService.isEnabled()) {
      final setUp = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Set up a PIN first'),
          content: const Text('"Lock this chat" uses your app PIN, which isn\'t set up yet.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Set up PIN')),
          ],
        ),
      );
      if (setUp != true || !mounted) return;
      final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)));
      if (result != true || !mounted) return;
    }
    await ChatLockService.setLocked(widget.conversationId, value);
    if (!mounted) return;
    setState(() => _locked = value);
  }

  Future<void> _loadHideState() async {
    final commonSetUp = await ChatLockService.isCommonSetUp();
    final commonHidden = (await ChatLockService.getCommonHiddenIds()).contains(widget.conversationId);
    final customHidden = await ChatLockService.hasCustomCode(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _commonSetUp = commonSetUp;
      _hiddenViaCommon = commonHidden;
      _hiddenViaCustom = customHidden;
    });
  }

  /// Chat is already open, so no extra verification needed here (unlike
  /// the forgot-code recovery flow in Settings > Hidden chats, which
  /// requires a password) — this is just "stop hiding," content untouched.
  // ---- Feature: timed mute ------------------------------------------------

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatUntil(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour < 12 ? 'AM' : 'PM';
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final time = '$hour12:$minute $suffix';
    return sameDay ? 'today $time' : '${months[dt.month - 1]} ${dt.day}, $time';
  }

  /// Turning the switch ON asks how long (1 hour / 8 hours / 24 hours /
  /// 1 week / Custom… / Always); turning it OFF unmutes immediately.
  Future<void> _onMuteSwitch(bool wantMuted) async {
    try {
      if (!wantMuted) {
        await _conversationService.setMuted(widget.conversationId, false);
        return;
      }
      final choice = await showMuteDurationSheet(context);
      if (choice == null) return;
      if (choice.isForever) {
        await _conversationService.setMuted(widget.conversationId, true);
      } else {
        await _conversationService.muteFor(widget.conversationId, choice.duration!);
      }
      _snack('Muted ${choice.label}');
    } catch (e) {
      _snack("Couldn't change mute — check your connection and try again.");
    }
  }

  // ---- Feature: permission-gated message forwarding -----------------------

  Future<void> _runForwardingAction(Future<void> Function() action, String successMessage) async {
    try {
      await action();
      _snack(successMessage);
    } catch (e) {
      _snack("Couldn't update forwarding — check your connection and try again.");
    }
  }

  /// One row that shows whichever of the four states this chat is in:
  ///  1. ON  — allowed for both people; the switch turns it OFF instantly,
  ///     no permission needed.
  ///  2. The other person has asked — Allow / Deny.
  ///  3. I have asked — waiting, with a way to cancel.
  ///  4. OFF (the default) — the switch asks the other person for
  ///     permission rather than turning anything on by itself.
  Widget _buildForwardingTile(ColorScheme scheme, Map<String, dynamic> data) {
    final enabled = _conversationService.isForwardingEnabled(data);
    final incoming = _conversationService.hasIncomingForwardingRequest(data);
    final mine = _conversationService.hasMyPendingForwardingRequest(data);
    final name = widget.peerUsername;

    if (enabled) {
      return SwitchListTile.adaptive(
        secondary: const Icon(Icons.forward_outlined),
        title: const Text('Forwarding & copying'),
        subtitle: const Text(
          'Allowed — either of you can forward and copy messages from this chat. Switch it off any time; no permission needed.',
        ),
        value: true,
        onChanged: (_) => _runForwardingAction(
          () => _conversationService.disableForwarding(widget.conversationId),
          'Forwarding turned off for this chat.',
        ),
      );
    }

    if (incoming) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(Icons.forward_to_inbox_outlined, color: scheme.primary),
              title: const Text('Forwarding & copying'),
              subtitle: Text('$name asked to be able to forward and copy messages from this chat. Allow it?'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _runForwardingAction(
                      () => _conversationService.clearForwardingRequest(widget.conversationId),
                      'Request declined.',
                    ),
                    child: const Text('Deny'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _runForwardingAction(
                      () => _conversationService.approveForwardingRequest(widget.conversationId),
                      'Forwarding turned on — either of you can switch it off any time.',
                    ),
                    child: const Text('Allow'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (mine) {
      return ListTile(
        leading: const Icon(Icons.hourglass_top_outlined),
        title: const Text('Forwarding & copying'),
        subtitle: Text('Waiting for $name to approve your request'),
        trailing: TextButton(
          onPressed: () => _runForwardingAction(
            () => _conversationService.clearForwardingRequest(widget.conversationId),
            'Request cancelled.',
          ),
          child: const Text('Cancel'),
        ),
      );
    }

    return SwitchListTile.adaptive(
      secondary: const Icon(Icons.forward_outlined),
      title: const Text('Forwarding & copying'),
      subtitle: Text('Restricted — nobody can forward or copy messages from this chat. Turning it on asks $name for permission first.'),
      value: false,
      onChanged: (_) => _runForwardingAction(
        () => _conversationService.requestForwarding(widget.conversationId),
        'Request sent to $name.',
      ),
    );
  }

  Future<void> _unhide() async {
    if (_hiddenViaCommon) {
      await ChatLockService.setHiddenCommon(widget.conversationId, false);
    } else if (_hiddenViaCustom) {
      await ChatLockService.removeCustomHiding(widget.conversationId);
    }
    if (!mounted) return;
    setState(() {
      _hiddenViaCommon = false;
      _hiddenViaCustom = false;
    });
  }

  Future<void> _openHideOptions() async {
    final choice = await showModalBottomSheet<String>(
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
                child: Text('Hide this chat using…', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.groups_2_outlined),
              title: const Text('The common code'),
              subtitle: Text(_commonSetUp ? 'Same code as your other common-hidden chats' : "Not set up yet — you'll set it up in Settings first"),
              onTap: () => Navigator.pop(sheetContext, 'common'),
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('A custom code just for this chat'),
              subtitle: const Text("A different code, used only to unlock this one chat"),
              onTap: () => Navigator.pop(sheetContext, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'common') {
      await _hideWithCommon();
    } else {
      await _hideWithCustom();
    }
  }

  Future<void> _hideWithCommon() async {
    if (!_commonSetUp) {
      final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const ChatLockSetupScreen()));
      await _loadHideState();
      if (result != true || !_commonSetUp) return;
    }
    await ChatLockService.setHiddenCommon(widget.conversationId, true);
    if (!mounted) return;
    // Hiding a chat you're currently looking at needs to actually take you
    // out of it — otherwise it'd be "hidden" from the list but still
    // sitting open right in front of you.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _hideWithCustom() async {
    final entry = await showModalBottomSheet<_CustomCodeEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CustomCodeSheet(),
    );
    if (entry == null || !mounted) return;
    await ChatLockService.setUpCustom(conversationId: widget.conversationId, method: entry.method, code: entry.code);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
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
          final muteUntil = _conversationService.muteExpiryFor(data);
          final archived = _conversationService.isArchivedByMe(data);
          final chatTtl = (data['chatTtlHours'] as num?)?.toInt();
          final ephemeralViewEnabled = data['ephemeralViewEnabled'] == true;

          return ListView(
            children: [
              ListTile(
                leading: UserAvatar(uid: widget.peerUid, name: widget.peerUsername),
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
                subtitle: Text(
                  !muted
                      ? 'Turn off alerts for this chat only — for an hour, a day, a week, or your own custom time'
                      : (muteUntil != null && muteUntil.isAfter(DateTime.now())
                          ? 'Muted until ${_formatUntil(muteUntil)}'
                          : 'Muted until you turn it back on'),
                ),
                value: muted,
                onChanged: _onMuteSwitch,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.archive_outlined),
                title: const Text('Archive chat'),
                subtitle: const Text('Hide from your main chat list — new messages still arrive normally'),
                value: archived,
                onChanged: (v) => _conversationService.setArchived(widget.conversationId, v),
              ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('Privacy & security', style: Theme.of(context).textTheme.titleSmall),
              ),
              _buildForwardingTile(scheme, data),
              (_hiddenViaCommon || _hiddenViaCustom)
                  ? ListTile(
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: const Text('This chat is hidden'),
                      subtitle: Text(
                        _hiddenViaCommon
                            ? 'Using your common code — type it into search to bring it back'
                            : "Using a custom code just for this chat — type it into search to bring it back",
                      ),
                      trailing: TextButton(onPressed: _unhide, child: const Text('Unhide')),
                    )
                  : ListTile(
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: const Text('Hide this chat'),
                      subtitle: const Text('Removed from your chat list entirely — pick the common code or set one just for this chat'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openHideOptions,
                    ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.lock_outline),
                title: const Text('Lock this chat'),
                subtitle: Text(
                  _locked
                      ? 'Your app PIN is required to open this chat — still shows normally in your chat list'
                      : 'Require your app PIN to open this chat. Independent of hiding — this chat still shows normally in your list',
                ),
                value: _locked,
                onChanged: _toggleLocked,
              ),
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _moderationService.myProfileStream(),
                builder: (context, profileSnapshot) {
                  final data = profileSnapshot.data?.data();
                  final global = (data?['notificationPrivacyGlobal'] as bool?) ?? false;
                  final peers = List<String>.from(data?['notificationPrivacyPeers'] ?? []);
                  final hideForThisChat = global || peers.contains(widget.peerUid);
                  return SwitchListTile.adaptive(
                    secondary: const Icon(Icons.notifications_off_outlined),
                    title: const Text('Hide name in notifications'),
                    subtitle: Text(
                      global
                          ? 'On for every chat (set in Settings > Account security) — can\'t turn off just for this one'
                          : hideForThisChat
                              ? 'On for this chat — notifications from ${widget.peerUsername} show "New message" instead of their name'
                              : 'Off for this chat',
                    ),
                    value: hideForThisChat,
                    onChanged: global ? null : (v) => _moderationService.setNotificationPrivacyForPeer(widget.peerUid, v),
                  );
                },
              ),
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _moderationService.myProfileStream(),
                builder: (context, profileSnapshot) {
                  final data = profileSnapshot.data?.data();
                  final globalContent = (data?['notificationPrivacyHideContentGlobal'] as bool?) ?? false;
                  final contentPeers = List<String>.from(data?['notificationPrivacyHideContentPeers'] ?? []);
                  final hideContentForThisChat = globalContent || contentPeers.contains(widget.peerUid);
                  return SwitchListTile.adaptive(
                    secondary: const Icon(Icons.notifications_paused_outlined),
                    title: const Text('Hide message preview'),
                    subtitle: Text(
                      globalContent
                          ? 'On for every chat (set in Settings > Account security) — can\'t turn off just for this one'
                          : hideContentForThisChat
                              ? 'On for this chat — no "sent you a photo" text, just a generic alert'
                              : 'Off for this chat',
                    ),
                    value: hideContentForThisChat,
                    onChanged: globalContent ? null : (v) => _moderationService.setNotificationContentPrivacyForPeer(widget.peerUid, v),
                  );
                },
              ),
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _moderationService.myProfileStream(),
                builder: (context, profileSnapshot) {
                  final data = profileSnapshot.data?.data();
                  final lastSeenGlobalOff = (data?['lastSeenVisible'] as bool?) == false;
                  final readReceiptsGlobalOff = (data?['readReceiptsEnabled'] as bool?) == false;
                  final lastSeenPeers = List<String>.from(data?['lastSeenHiddenPeers'] ?? []);
                  final readReceiptPeers = List<String>.from(data?['readReceiptsDisabledPeers'] ?? []);
                  final lastSeenHidden = lastSeenGlobalOff || lastSeenPeers.contains(widget.peerUid);
                  final readReceiptsOff = readReceiptsGlobalOff || readReceiptPeers.contains(widget.peerUid);
                  return Column(
                    children: [
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.visibility_off_outlined),
                        title: const Text('Hide my last seen from them'),
                        subtitle: Text(
                          lastSeenGlobalOff
                              ? "Already off for everyone (Settings > Account security) — can't turn off just for this one"
                              : lastSeenHidden
                                  ? "On — ${widget.peerUsername} can't see when you were last online or whether you're online now"
                                  : 'Off for this chat',
                        ),
                        value: lastSeenHidden,
                        onChanged: lastSeenGlobalOff ? null : (v) => _moderationService.setLastSeenHiddenForPeer(widget.peerUid, v),
                      ),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.done_all),
                        title: const Text('Hide read receipts from them'),
                        subtitle: Text(
                          readReceiptsGlobalOff
                              ? "Already off for everyone (Settings > Account security) — can't turn off just for this one"
                              : readReceiptsOff
                                  ? "On — ${widget.peerUsername} won't see blue ticks when you've read their messages. What you see of theirs is up to their own setting, not this one"
                                  : 'Off for this chat',
                        ),
                        value: readReceiptsOff,
                        onChanged: readReceiptsGlobalOff ? null : (v) => _moderationService.setReadReceiptsDisabledForPeer(widget.peerUid, v),
                      ),
                    ],
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: const Text('Pause this chat'),
                subtitle: const Text(
                  "Hide this chat and stop messages both ways for a set time — either of you can end it early",
                ),
                onTap: _pauseChat,
              ),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.timer_off_outlined),
                title: const Text('Clear on exit'),
                subtitle: Text(
                  ephemeralViewEnabled
                      ? "On — closing this chat wipes everything in it from THIS device only. It comes back empty next time you open it, even if new messages arrived while you were out"
                      : 'When on, leaving this chat clears it from your device — nothing is sent to ${widget.peerUsername} or deleted for them',
                ),
                value: ephemeralViewEnabled,
                onChanged: (v) => _conversationService.setEphemeralViewEnabled(widget.conversationId, v),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Auto-delete messages'),
                subtitle: Text(_ttlLabel(chatTtl)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openTtlPicker(chatTtl),
              ),
              ListTile(
                leading: const Icon(Icons.perm_media_outlined),
                title: const Text('Media, links and voice messages'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatMediaBrowserScreen(conversationId: widget.conversationId, title: widget.peerUsername)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Chat theme'),
                subtitle: const Text('Wallpaper and bubble colour'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatWallpaperScreen(conversationId: widget.conversationId)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Muted keywords for this chat'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => KeywordMuteScreen(conversationId: widget.conversationId)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.auto_delete_outlined),
                title: const Text('Auto-wipe if inactive'),
                subtitle: Text(_inactivityOverrideLabel()),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickInactivityOverride,
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

class _CustomCodeEntry {
  final String method;
  final String code;
  const _CustomCodeEntry({required this.method, required this.code});
}

/// Bottom-sheet content: choose password or emoji, enter it, confirm it —
/// same enter/confirm shape as the common-code setup flow in
/// ChatLockSetupScreen, just scoped to one chat and returned via
/// Navigator.pop instead of written straight to storage, since the
/// caller (chat_settings_screen's _hideWithCustom) needs conversationId to
/// actually save it.
class _CustomCodeSheet extends StatefulWidget {
  const _CustomCodeSheet();

  @override
  State<_CustomCodeSheet> createState() => _CustomCodeSheetState();
}

enum _CustomStep { chooseMethod, enterCode, confirmCode }

class _CustomCodeSheetState extends State<_CustomCodeSheet> {
  _CustomStep _step = _CustomStep.chooseMethod;
  String _method = 'password';
  final _passwordController = TextEditingController();
  final List<String> _emojiSequence = [];
  String? _firstEntry;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  String get _currentCode =>
      _method == 'password' ? _passwordController.text.trim() : _emojiSequence.join();

  void _startWith(String method) {
    setState(() {
      _method = method;
      _step = _CustomStep.enterCode;
      _firstEntry = null;
      _error = null;
      _passwordController.clear();
      _emojiSequence.clear();
    });
  }

  void _submit() {
    final code = _currentCode;
    if (code.isEmpty) return;
    if (_step == _CustomStep.enterCode) {
      setState(() {
        _firstEntry = code;
        _step = _CustomStep.confirmCode;
        _error = null;
        _passwordController.clear();
        _emojiSequence.clear();
      });
      return;
    }
    if (code != _firstEntry) {
      setState(() {
        _error = "Those didn't match — try again from the start.";
        _step = _CustomStep.enterCode;
        _firstEntry = null;
        _passwordController.clear();
        _emojiSequence.clear();
      });
      return;
    }
    Navigator.pop(context, _CustomCodeEntry(method: _method, code: code));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_step == _CustomStep.chooseMethod) ...[
            const Text('Choose how to unlock this chat:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('Password'),
                onTap: () => _startWith('password'),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Text('😀', style: TextStyle(fontSize: 20)),
                title: const Text('Emoji sequence'),
                onTap: () => _startWith('emoji'),
              ),
            ),
          ] else ...[
            Text(
              _step == _CustomStep.confirmCode ? 'Enter it again to confirm' : (_method == 'password' ? 'Choose a password' : 'Choose your emoji sequence'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            if (_method == 'password')
              TextField(
                controller: _passwordController,
                obscureText: true,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Password'),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(_emojiSequence.isEmpty ? 'Tap emoji below' : _emojiSequence.join(' '), style: const TextStyle(fontSize: 20)),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _suggestedEmoji
                    .map((e) => InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => setState(() => _emojiSequence.add(e)),
                          child: Padding(padding: const EdgeInsets.all(4), child: Text(e, style: const TextStyle(fontSize: 22))),
                        ))
                    .toList(),
              ),
              if (_emojiSequence.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: () => setState(() => _emojiSequence.removeLast()), child: const Text('Remove last')),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _currentCode.isEmpty ? null : _submit,
                child: Text(_step == _CustomStep.confirmCode ? 'Confirm' : 'Next'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

const _suggestedEmoji = [
  '🔒', '🗝️', '⭐', '🌙', '🔥', '💎', '🎯', '🐱', '🌸', '☕',
  '🎵', '🍀', '🦋', '⚡', '🌊', '🍎', '🎈', '🐧', '🌵', '🎧',
];
