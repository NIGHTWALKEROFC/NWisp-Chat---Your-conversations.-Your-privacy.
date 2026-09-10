import 'package:flutter/material.dart';
import '../../models/local_message.dart';
import '../../services/auth_service.dart';
import '../../services/chat_lock_service.dart';
import '../../services/local_message_store.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Forgot your hide code? This is the only way back in.
///
/// Deliberately NOT a quiet "turn hiding off" toggle — that used to let
/// anyone holding the unlocked phone just switch hiding off and see
/// everything. Getting back in now requires re-proving it's really the
/// account owner (password) and an explicit typed confirmation, exactly
/// like DeleteAccountScreen's pattern — and it WIPES the content of
/// whatever's being reset, same as a fresh chat, rather than silently
/// exposing what was hidden.
///
/// [custom] false = reset the COMMON code, wiping every chat hidden under
/// it. [custom] true = pick ONE chat that has its own custom code and
/// reset just that one — every other custom-coded chat, and the common
/// code, are left alone.
class ResetHiddenChatsScreen extends StatefulWidget {
  final bool custom;
  const ResetHiddenChatsScreen({super.key, required this.custom});

  @override
  State<ResetHiddenChatsScreen> createState() => _ResetHiddenChatsScreenState();
}

class _ResetHiddenChatsScreenState extends State<ResetHiddenChatsScreen> {
  static const _confirmWord = 'RESET';

  final _authService = AuthService();
  final _confirmController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  // Only used when widget.custom == true.
  List<ConversationSummary> _pickerOptions = [];
  bool _loadingPicker = true;
  String? _selectedConversationId;

  @override
  void initState() {
    super.initState();
    if (widget.custom) _loadPicker();
  }

  Future<void> _loadPicker() async {
    final customIds = await ChatLockService.getCustomHiddenIds();
    final summaries = await LocalMessageStore.watchSummaries().first;
    final matches = summaries.where((s) => customIds.contains(s.conversationId)).toList();
    // A custom code could exist for a chat that has no local messages yet
    // (a fresh conversation, hidden before anything was ever sent) — that
    // wouldn't show up in watchSummaries at all. Represent those too, so
    // "forgot the code" recovery always has a way in regardless.
    final coveredIds = matches.map((s) => s.conversationId).toSet();
    final missingIds = customIds.difference(coveredIds);
    if (!mounted) return;
    setState(() {
      _pickerOptions = matches;
      _loadingPicker = false;
    });
    if (missingIds.isNotEmpty) {
      setState(() => _extraIds = missingIds.toList());
    }
  }

  List<String> _extraIds = [];

  Future<String> _labelFor(ConversationSummary s) async {
    if (s.isGroup) return s.groupName ?? 'Group chat';
    final doc = await FirebaseFirestore.instance.collection('users').doc(s.peerUid).get();
    return (doc.data()?['username'] as String?) ?? 'Unknown';
  }

  bool get _canSubmit =>
      !_busy &&
      _confirmController.text.trim() == _confirmWord &&
      _passwordController.text.isNotEmpty &&
      (!widget.custom || _selectedConversationId != null);

  Future<void> _reset() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _authService.reauthenticate(_passwordController.text);
      if (widget.custom) {
        final id = _selectedConversationId!;
        await ChatLockService.resetCustom(id);
        await LocalMessageStore.clearConversation(id);
      } else {
        final ids = await ChatLockService.resetCommon();
        for (final id in ids) {
          await LocalMessageStore.clearConversation(id);
        }
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not verify your password. Check it and try again.';
      });
    }
  }

  @override
  void dispose() {
    _confirmController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.custom ? 'Reset a custom-coded chat' : 'Reset common hidden chats')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error, size: 40),
              const SizedBox(height: 12),
              Text('This wipes chat content', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                widget.custom
                    ? 'Pick the chat below. Its messages will be permanently deleted from this device and it will '
                        'reappear on your home screen as a fresh, empty chat, no longer hidden. This cannot be undone.'
                    : 'Every chat currently hidden with your common code will have its messages permanently deleted '
                        'from this device and reappear on your home screen as fresh, empty chats. Chats hidden with '
                        'their own custom code are not affected. This cannot be undone.',
              ),
              if (widget.custom) ...[
                const SizedBox(height: 20),
                Text('Which chat?', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_loadingPicker)
                  const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                else if (_pickerOptions.isEmpty && _extraIds.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No chats with a custom code right now.', style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (final s in _pickerOptions)
                          FutureBuilder<String>(
                            future: _labelFor(s),
                            builder: (context, snap) {
                              final label = snap.data ?? '…';
                              return RadioListTile<String>(
                                value: s.conversationId,
                                groupValue: _selectedConversationId,
                                title: Text(label),
                                onChanged: (v) => setState(() => _selectedConversationId = v),
                              );
                            },
                          ),
                        for (final id in _extraIds)
                          RadioListTile<String>(
                            value: id,
                            groupValue: _selectedConversationId,
                            title: const Text('Chat with no messages yet'),
                            onChanged: (v) => setState(() => _selectedConversationId = v),
                          ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              Text('Type $_confirmWord to confirm', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmController,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: _confirmWord),
              ),
              const SizedBox(height: 16),
              Text('Confirm your account password', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: scheme.error),
                  onPressed: _canSubmit ? _reset : null,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Wipe and reset'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
