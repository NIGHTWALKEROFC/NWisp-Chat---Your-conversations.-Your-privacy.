import 'package:flutter/material.dart';
import '../../services/intruder_photo_service.dart';
import '../../services/media_vault_service.dart';
import '../vault/media_vault_screen.dart';

/// Settings > Security > Intruder photo. Off by default.
class IntruderPhotoScreen extends StatefulWidget {
  const IntruderPhotoScreen({super.key});

  @override
  State<IntruderPhotoScreen> createState() => _IntruderPhotoScreenState();
}

class _IntruderPhotoScreenState extends State<IntruderPhotoScreen> {
  final _service = IntruderPhotoService.instance;
  bool _loading = true;
  bool _enabled = false;
  int _threshold = IntruderPhotoService.defaultThreshold;
  bool _vaultReady = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _service.isEnabled();
    final threshold = await _service.getThreshold();
    final vaultReady = await MediaVaultService.instance.isSetUp();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _threshold = threshold;
      _vaultReady = vaultReady;
      _loading = false;
    });
  }

  Future<void> _problem(String title, String message, {bool offerVault = false}) async {
    final openVault = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('OK')),
          if (offerVault) FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Set up vault')),
        ],
      ),
    );
    if (openVault == true && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
      );
      await _load();
    }
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await _service.setEnabled(false);
      if (mounted) setState(() => _enabled = false);
      return;
    }
    setState(() => _working = true);
    final problem = await _service.prepare();
    if (!mounted) return;
    setState(() => _working = false);
    if (problem != null) {
      await _problem(
        "Couldn't turn this on",
        problem,
        offerVault: problem.startsWith('Set up your Media vault'),
      );
      return;
    }
    await _service.setEnabled(true);
    if (mounted) setState(() => _enabled = true);
  }

  Future<void> _test() async {
    setState(() => _working = true);
    final problem = await _service.testCapture();
    if (!mounted) return;
    setState(() => _working = false);
    if (problem == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('It worked — a test photo was saved in your Media vault, marked "Intruder".')),
      );
    } else {
      await _problem(
        "This phone didn't allow it",
        "$problem\n\nSome phones refuse to take a photo unless a camera preview is showing on screen. If that's the case here, this feature can't work on this phone.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Intruder photo')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    'If someone enters the wrong app PIN several times, the front camera quietly takes a photo. '
                    'It is saved in your Media vault — protected by the vault PIN — and you are told the next time you unlock.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.no_photography_outlined),
                  title: const Text('Take a photo after wrong PINs'),
                  subtitle: const Text('Off by default'),
                  value: _enabled,
                  onChanged: _working ? null : _toggle,
                ),
                if (_working) const LinearProgressIndicator(),
                if (_enabled) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text('Take the photo after', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final n in IntruderPhotoService.thresholdOptions)
                          ChoiceChip(
                            label: Text(n == 1 ? '1 wrong PIN' : '$n wrong PINs'),
                            selected: _threshold == n,
                            onSelected: (_) async {
                              setState(() => _threshold = n);
                              await _service.setThreshold(n);
                            },
                          ),
                      ],
                    ),
                  ),
                  if (!_vaultReady)
                    ListTile(
                      leading: Icon(Icons.warning_amber_rounded, color: scheme.error),
                      title: const Text('Your Media vault is not set up'),
                      subtitle: const Text('Photos can\'t be saved until it is.'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _problem('Set up your vault', 'Intruder photos are saved in your Media vault.', offerVault: true),
                    ),
                  ListTile(
                    leading: const Icon(Icons.camera_front_outlined),
                    title: const Text('Test it now'),
                    subtitle: const Text('Takes a photo the same way the lock screen would, so you can check your phone allows it'),
                    onTap: _working ? null : _test,
                  ),
                  ListTile(
                    leading: const Icon(Icons.enhanced_encryption_outlined),
                    title: const Text('Open Media vault'),
                    subtitle: const Text('Intruder photos have a red label with the time'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(settings: const RouteSettings(name: '/vault'), builder: (_) => const MediaVaultScreen()),
                    ).then((_) => _load()),
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Limits: at most 5 photos per attempt streak. It only works while the app is open on the lock screen, '
                    'and some phones refuse to take a photo without a visible preview — use "Test it now" to check yours.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
    );
  }
}
