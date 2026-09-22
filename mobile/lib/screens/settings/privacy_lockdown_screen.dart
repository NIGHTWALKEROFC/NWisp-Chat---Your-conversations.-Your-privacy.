import 'package:flutter/material.dart';
import '../../services/privacy_checkup_service.dart';
import '../security/pin_screen.dart';

/// "Make it 100% private": first shows exactly what will be switched on, and
/// only when the person presses the button at the bottom does it do it.
class PrivacyLockdownScreen extends StatefulWidget {
  const PrivacyLockdownScreen({super.key});

  @override
  State<PrivacyLockdownScreen> createState() => _PrivacyLockdownScreenState();
}

class _PrivacyLockdownScreenState extends State<PrivacyLockdownScreen> {
  Map<String, dynamic>? _raw;
  bool _working = false;
  bool _done = false;

  // Things worth knowing before switching a particular one on.
  static const Map<String, String> _heads = {
    'login_approval': 'From now on a new sign-in must be approved from THIS phone — keep this phone safe.',
    'hide_read_receipts': 'Works both ways: you will not see other people\'s read receipts either.',
    'hide_badge': 'The app icon will stop showing an unread number.',
  };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final raw = await PrivacyCheckupService.readRaw();
    if (mounted) setState(() => _raw = raw);
  }

  Future<void> _setUpLock() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PinScreen(mode: PinScreenMode.setup)));
    await _reload();
  }

  Future<void> _apply() async {
    final raw = _raw;
    if (raw == null) return;
    setState(() => _working = true);
    await PrivacyCheckupService.applyLockdown(raw);
    await _reload();
    if (mounted) {
      setState(() {
        _working = false;
        _done = true;
      });
    }
  }

  Future<void> _undo() async {
    setState(() => _working = true);
    await PrivacyCheckupService.undoLastLockdown();
    await _reload();
    if (mounted) {
      setState(() {
        _working = false;
        _done = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = _raw;
    if (raw == null) {
      return Scaffold(appBar: AppBar(title: const Text('Make it 100% private')), body: const Center(child: CircularProgressIndicator()));
    }
    final plan = PrivacyCheckupService.plan(raw);
    final lockOn = raw['appLock'] == true;
    final score = PrivacyCheckupService.score(raw);
    final alreadyOn = kPrivacyItems.where((i) => PrivacyCheckupService.isOn(i.id, raw)).toList();

    if (_done) {
      return Scaffold(
        appBar: AppBar(title: const Text('Make it 100% private')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.verified_user, size: 80, color: Colors.green),
                const SizedBox(height: 16),
                const Text('Done', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  '$score of ${kPrivacyItems.length} settings are on.'
                  '${lockOn ? '' : '\nSet up App lock to switch on the rest.'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                TextButton.icon(
                  onPressed: _working ? null : _undo,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo — put my old settings back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Make it 100% private')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    plan.isEmpty
                        ? 'Everything that can be switched on automatically already is.'
                        : "This is what will be switched on. Nothing changes until you press the button at the bottom, and you can undo it afterwards.",
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (!lockOn)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: scheme.tertiaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(Icons.pin_outlined, color: scheme.onTertiaryContainer),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              "App lock is off. Set a PIN to include the lock settings too — you choose the PIN, so it can't be done for you.",
                              style: TextStyle(color: scheme.onTertiaryContainer),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: _setUpLock, child: const Text('Set PIN')),
                        ],
                      ),
                    ),
                  ),
                if (plan.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text('Will be turned on (${plan.length})', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
                  ),
                for (final item in plan)
                  ListTile(
                    leading: Icon(item.icon, color: scheme.primary),
                    title: Text(item.title),
                    subtitle: Text(_heads[item.id] ?? item.description),
                    trailing: const Icon(Icons.arrow_forward, size: 18),
                  ),
                if (alreadyOn.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text('Already on (${alreadyOn.length})', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
                  ),
                  for (final item in alreadyOn)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.check_circle, color: Colors.green),
                      title: Text(item.title),
                    ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Not included: auto-delete messages and auto-wipe of inactive chats. They delete things, so they stay your own choice in Settings.',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: (_working || plan.isEmpty) ? null : _apply,
                  icon: _working
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.shield),
                  label: Text(plan.isEmpty ? 'Nothing left to turn on' : 'Turn all on (${plan.length})'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
