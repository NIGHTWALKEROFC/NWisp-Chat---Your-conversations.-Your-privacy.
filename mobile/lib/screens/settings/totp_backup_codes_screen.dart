import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Feature: TOTP two-factor authentication — shown exactly once right
/// after enabling 2FA (TotpSetupScreen) or after regenerating codes.
/// These 10 codes are the only way back into the account if the
/// person's phone with the authenticator app is ever lost, so the whole
/// point of this screen is making sure they actually save them
/// somewhere before moving on — there's no "view backup codes" screen
/// anywhere else in the app, because the server only ever returns the
/// plaintext codes at the moment they're generated (see
/// totp-enroll-confirm/index.ts and totp-regenerate-backup-codes/index.ts
/// — only hashes are stored after that).
class TotpBackupCodesScreen extends StatefulWidget {
  final List<String> codes;
  /// True when this is the very first reveal (right after enabling 2FA) —
  /// changes the title/copy slightly and, critically, requires an
  /// explicit "I've saved these" confirmation before leaving, since
  /// there's no other path back to them if the person taps away too fast.
  final bool isInitialSetup;

  const TotpBackupCodesScreen({super.key, required this.codes, this.isInitialSetup = false});

  @override
  State<TotpBackupCodesScreen> createState() => _TotpBackupCodesScreenState();
}

class _TotpBackupCodesScreenState extends State<TotpBackupCodesScreen> {
  bool _confirmedSaved = false;

  String get _allCodesText =>
      'NWisp two-factor backup codes\nEach one can be used once, instead of your authenticator app.\n\n'
      '${widget.codes.join('\n')}';

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _allCodesText));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup codes copied')));
    }
  }

  Future<void> _shareAll() => Share.share(_allCodesText);

  Future<bool> _onWillPop() async {
    if (!widget.isInitialSetup || _confirmedSaved) return true;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("You won't see these again"),
        content: const Text(
          "These codes only show once. If you leave without saving them and later lose access to your "
          "authenticator app, you could be locked out of your account. Leave anyway?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Leave anyway')),
        ],
      ),
    );
    return proceed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !widget.isInitialSetup || _confirmedSaved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop() && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Backup codes')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(Icons.shield_outlined, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              widget.isInitialSetup
                  ? "Two-factor authentication is on. Save these backup codes somewhere safe."
                  : 'Your new backup codes',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Each code works once, and lets you sign in if you ever lose access to your authenticator app. '
              'Any codes from before this are no longer valid.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 10,
                  children: [
                    for (final code in widget.codes)
                      SizedBox(
                        width: 130,
                        child: Text(
                          code,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyAll,
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Copy all'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _shareAll,
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (widget.isInitialSetup) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _confirmedSaved,
                onChanged: (v) => setState(() => _confirmedSaved = v ?? false),
                title: const Text("I've saved these codes somewhere safe"),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _confirmedSaved ? () => Navigator.of(context).pop() : null,
                child: const Text('Done'),
              ),
            ] else
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
          ],
        ),
      ),
    );
  }
}
