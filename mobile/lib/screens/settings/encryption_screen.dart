import 'package:flutter/material.dart';
import '../../services/post_quantum_service.dart';
import '../../widgets/nwisp_ui.dart';

/// Settings > Encryption & quantum safety.
class EncryptionScreen extends StatefulWidget {
  const EncryptionScreen({super.key});

  @override
  State<EncryptionScreen> createState() => _EncryptionScreenState();
}

class _EncryptionScreenState extends State<EncryptionScreen> {
  final _pq = PostQuantumService.instance;
  bool _strict = false;
  bool _loaded = false;
  String _keyId = '—';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final strict = await _pq.isStrict();
    final id = await _pq.currentKeyId();
    if (!mounted) return;
    setState(() {
      _strict = strict;
      _keyId = id;
      _loaded = true;
    });
  }

  Widget _row(IconData icon, String title, String body, {Color? color}) => ListTile(
        leading: Icon(icon, color: color ?? Theme.of(context).colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(body, style: const TextStyle(fontSize: 12.5, height: 1.3)),
      );

  @override
  Widget build(BuildContext context) {
    final ok = _pq.available;
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption & quantum safety')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                NwispCard(
                  child: Column(
                    children: [
                      _row(Icons.lock_rounded, 'Signal Double Ratchet (X25519)',
                          'Every message gets its own key. Old keys are erased, so a leaked key can\'t open past or future messages.'),
                      const Divider(height: 1, indent: 56),
                      _row(
                        ok ? Icons.verified_rounded : Icons.error_outline,
                        'Post-quantum layer (ML-KEM-768)',
                        ok
                            ? 'Active. Every message is sealed a second time with a key from ML-KEM-768 (the NIST post-quantum standard). '
                                'Recorded messages stay unreadable even if quantum computers break today\'s encryption.'
                            : 'Not working on this phone (self-test failed), so messages use the classical layer only.',
                        color: ok ? Colors.green : Theme.of(context).colorScheme.error,
                      ),
                      const Divider(height: 1, indent: 56),
                      _row(Icons.autorenew_rounded, 'Key rotation',
                          'Your post-quantum key changes every 7 days and old ones are deleted after 30 days.\nCurrent key: $_keyId'),
                      const Divider(height: 1, indent: 56),
                      _row(Icons.perm_media_outlined, 'Photos, videos & voice notes',
                          'Each file is encrypted on your phone with its own random AES-256 key before upload. The key travels inside the encrypted message.'),
                      const Divider(height: 1, indent: 56),
                      _row(Icons.storage_rounded, 'On this phone', 'Your message database and keys are encrypted at rest, and screenshots are blocked.'),
                      const Divider(height: 1, indent: 56),
                      _row(Icons.phone_in_talk_outlined, 'Voice calls', 'Audio is encrypted between the two phones (DTLS-SRTP).'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                NwispCard(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.security_rounded),
                    title: const Text('Strict quantum-safe mode', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text(
                      "Refuse to send to anyone who hasn't got the post-quantum layer yet, instead of sending with classical encryption only. "
                      'Contacts on an older version of the app won\'t be able to receive your messages until they update.',
                      style: TextStyle(fontSize: 12.5, height: 1.3),
                    ),
                    value: _strict,
                    onChanged: ok
                        ? (v) async {
                            await _pq.setStrict(v);
                            if (mounted) setState(() => _strict = v);
                          }
                        : null,
                  ),
                ),
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Secret chats always use both layers plus brand-new keys, and never touch the strict-mode switch.',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
    );
  }
}
