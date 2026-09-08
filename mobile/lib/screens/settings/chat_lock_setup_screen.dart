import 'package:flutter/material.dart';
import '../../services/chat_lock_service.dart';

const _suggestedEmoji = [
  '🔒', '🗝️', '⭐', '🌙', '🔥', '💎', '🎯', '🐱', '🌸', '☕',
  '🎵', '🍀', '🦋', '⚡', '🌊', '🍎', '🎈', '🐧', '🌵', '🎧',
];

/// Set up, change, or turn off the code used to unlock hidden chats (see
/// ChatLockService and ChatListScreen's secret-code search-bar detection).
class ChatLockSetupScreen extends StatefulWidget {
  const ChatLockSetupScreen({super.key});

  @override
  State<ChatLockSetupScreen> createState() => _ChatLockSetupScreenState();
}

enum _Step { chooseMethod, enterCode, confirmCode }

class _ChatLockSetupScreenState extends State<ChatLockSetupScreen> {
  late Future<bool> _isSetUpFuture;
  String _method = 'password';
  _Step _step = _Step.chooseMethod;
  final _passwordController = TextEditingController();
  final List<String> _emojiSequence = [];
  String? _firstEntry;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _isSetUpFuture = ChatLockService.isSetUp();
  }

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
      _save(code);
    }
  }

  Future<void> _save(String code) async {
    setState(() => _busy = true);
    await ChatLockService.setUp(method: _method, code: code);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _turnOff() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off chat hiding?'),
        content: const Text('Every currently hidden chat will become visible again in your normal chat list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Turn off')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChatLockService.disable();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat hiding')),
      body: FutureBuilder<bool>(
        future: _isSetUpFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          if (snapshot.data == true && _step == _Step.chooseMethod) {
            return _buildAlreadySetUp();
          }
          return _buildSetupFlow();
        },
      ),
    );
  }

  Widget _buildAlreadySetUp() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Chat hiding is turned on.'),
          const SizedBox(height: 8),
          Text(
            'Hidden chats stay out of your normal chat list. Type your code into the search bar '
            'at the top of the chat list to reveal them.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: () => _startWith(_method), child: const Text('Change code')),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: _turnOff,
            child: const Text('Turn off chat hiding'),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupFlow() {
    if (_step == _Step.chooseMethod) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hide specific chats from your normal chat list, unlockable only by you — nothing '
              "anywhere hints that anything is hidden. Choose how you'll unlock them:",
            ),
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
          const SizedBox(height: 20),
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
