import 'package:flutter/material.dart';
import '../../services/chat_lock_service.dart';
import '../security/hidden_chat_pin_screen.dart';
import 'reset_hidden_chats_screen.dart';

const _suggestedEmoji = [
  '🔒', '🗝️', '⭐', '🌙', '🔥', '💎', '🎯', '🐱', '🌸', '☕',
  '🎵', '🍀', '🦋', '⚡', '🌊', '🍎', '🎈', '🐧', '🌵', '🎧',
];

/// Hidden-chats settings hub. Covers the COMMON hide code (shared across
/// however many chats use it), a summary of chats using their OWN custom
/// code instead (set from that chat's own Chat Settings screen — not
/// here), the forgot-code recovery/reset flow for each, and the optional
/// separate hidden-chats PIN second factor. See ChatLockService's own
/// header comment for the full design.
class ChatLockSetupScreen extends StatefulWidget {
  const ChatLockSetupScreen({super.key});

  @override
  State<ChatLockSetupScreen> createState() => _ChatLockSetupScreenState();
}

enum _Step { hub, chooseMethod, enterCode, confirmCode }

class _ChatLockSetupScreenState extends State<ChatLockSetupScreen> {
  bool _loaded = false;
  bool _commonSetUp = false;
  String _commonMethod = 'password';
  int _customCount = 0;
  bool _pinEnabled = false;

  _Step _step = _Step.hub;
  String _method = 'password';
  final _passwordController = TextEditingController();
  final List<String> _emojiSequence = [];
  String? _firstEntry;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final setUp = await ChatLockService.isCommonSetUp();
    final method = await ChatLockService.getCommonMethod();
    final customIds = await ChatLockService.getCustomHiddenIds();
    final pinEnabled = await ChatLockService.isPinEnabled();
    if (!mounted) return;
    setState(() {
      _commonSetUp = setUp;
      _commonMethod = method ?? 'password';
      _customCount = customIds.length;
      _pinEnabled = pinEnabled;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  String get _currentCode =>
      _method == 'password' ? _passwordController.text.trim() : _emojiSequence.join();

  void _startCommonSetup() {
    setState(() {
      _method = _commonSetUp ? _commonMethod : 'password';
      _step = _commonSetUp ? _Step.enterCode : _Step.chooseMethod;
      _firstEntry = null;
      _error = null;
      _passwordController.clear();
      _emojiSequence.clear();
    });
  }

  void _startWith(String method) {
    setState(() {
      _method = method;
      _step = _Step.enterCode;
      _firstEntry = null;
      _error = null;
      _passwordController.clear();
      _emojiSequence.clear();
    });
  }

  void _submitCurrentEntry() {
    final code = _currentCode;
    if (code.isEmpty) return;
    if (_step == _Step.enterCode) {
      setState(() {
        _firstEntry = code;
        _step = _Step.confirmCode;
        _error = null;
        _passwordController.clear();
        _emojiSequence.clear();
      });
      return;
    }
    if (_step == _Step.confirmCode) {
      if (code != _firstEntry) {
        setState(() {
          _error = "Those didn't match — try again from the start.";
          _step = _Step.enterCode;
          _firstEntry = null;
          _passwordController.clear();
          _emojiSequence.clear();
        });
        return;
      }
      _saveCommon(code);
    }
  }

  Future<void> _saveCommon(String code) async {
    setState(() => _busy = true);
    await ChatLockService.setUpCommon(method: _method, code: code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = _Step.hub;
    });
    await _load();
  }

  Future<void> _togglePin(bool value) async {
    if (value) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const HiddenChatPinScreen(mode: HiddenChatPinScreenMode.setup)),
      );
      if (ok != true) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Turn off hidden-chats PIN?'),
          content: const Text('A hide code alone will be enough to reveal hidden chats again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Turn off')),
          ],
        ),
      );
      if (confirmed != true) return;
      await ChatLockService.disablePin();
    }
    await _load();
  }

  Future<void> _resetCommon() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ResetHiddenChatsScreen(custom: false)),
    );
    if (result == true) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Common hidden chats were reset and are back on your home screen.')));
      }
    }
  }

  Future<void> _resetCustom() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ResetHiddenChatsScreen(custom: true)),
    );
    if (result == true) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('That chat was reset and is back on your home screen.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hidden chats')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : (_step == _Step.hub ? _buildHub() : _buildSetupFlow()),
    );
  }

  Widget _buildHub() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Hide specific chats from your normal chat list — nothing anywhere hints that anything is '
          'hidden. Each chat uses either the one common code below, or its own custom code (set from '
          "that chat's own settings).",
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        Text('Common code', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(_commonSetUp ? Icons.lock_outline : Icons.lock_open_outlined),
                title: Text(_commonSetUp ? 'Common code is set up' : 'Not set up yet'),
                subtitle: Text(
                  _commonSetUp
                      ? 'Type it into the search bar on the chat list to reveal every chat hidden with it.'
                      : 'Set a code any number of chats can share.',
                ),
                trailing: TextButton(
                  onPressed: _startCommonSetup,
                  child: Text(_commonSetUp ? 'Change' : 'Set up'),
                ),
              ),
              if (_commonSetUp)
                ListTile(
                  leading: Icon(Icons.restart_alt, color: scheme.error),
                  title: Text('Forgot your common code?', style: TextStyle(color: scheme.error)),
                  subtitle: const Text('Wipes and un-hides every chat hidden with it'),
                  onTap: _resetCommon,
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Custom per-chat codes', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: Text(_customCount == 0 ? 'No chats use their own code' : '$_customCount chat(s) use their own code'),
                subtitle: const Text("Set one from that chat's own settings — not here."),
              ),
              if (_customCount > 0)
                ListTile(
                  leading: Icon(Icons.restart_alt, color: scheme.error),
                  title: Text('Forgot a custom code?', style: TextStyle(color: scheme.error)),
                  subtitle: const Text('Pick one chat to wipe and un-hide'),
                  onTap: _resetCustom,
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Extra security', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile.adaptive(
            secondary: const Icon(Icons.pin_outlined),
            title: const Text('Require a PIN too'),
            subtitle: Text(
              _pinEnabled
                  ? 'On — a separate PIN is asked for after a correct hide code, before hidden chats show.'
                  : 'Off — a correct hide code alone reveals hidden chats. Optional extra step if you want it.',
            ),
            value: _pinEnabled,
            onChanged: _togglePin,
          ),
        ),
      ],
    );
  }

  Widget _buildSetupFlow() {
    if (_step == _Step.chooseMethod) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose how you\'ll unlock chats hidden with the common code:'),
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('Password'),
                subtitle: const Text('Any text you choose'),
                onTap: () => _startWith('password'),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Text('😀', style: TextStyle(fontSize: 20)),
                title: const Text('Emoji sequence'),
                subtitle: const Text('Pick a short sequence of emoji'),
                onTap: () => _startWith('emoji'),
              ),
            ),
          ],
        ),
      );
    }

    final isConfirm = _step == _Step.confirmCode;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isConfirm ? 'Enter it again to confirm' : (_method == 'password' ? 'Choose a password' : 'Choose your emoji sequence'),
            style: Theme.of(context).textTheme.titleMedium,
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
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  _emojiSequence.isEmpty ? 'Tap emoji below' : _emojiSequence.join(' '),
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _suggestedEmoji
                  .map(
                    (e) => InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => setState(() => _emojiSequence.add(e)),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                  )
                  .toList(),
            ),
            if (_emojiSequence.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _emojiSequence.removeLast()),
                  child: const Text('Remove last'),
                ),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : () => setState(() => _step = _Step.hub),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_busy || _currentCode.isEmpty) ? null : _submitCurrentEntry,
              child: Text(isConfirm ? 'Confirm' : 'Next'),
            ),
          ),
        ],
      ),
    );
  }
}
