import 'package:flutter/material.dart';
import 'otp_code_field.dart';

/// Feature: TOTP two-factor authentication — the confirmation step shown
/// before disabling 2FA or regenerating backup codes (see
/// totp_setup_screen.dart). Both server-side operations require proving
/// the person currently holds a valid factor (code or backup code), not
/// just that they're signed in — see totp-disable/index.ts and
/// totp-regenerate-backup-codes/index.ts's own comments for why.
///
/// Returns a map with EITHER a 'code' or a 'backupCode' key once the
/// person submits, or null if they dismissed the sheet.
Future<Map<String, String>?> showTotpFactorSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
}) {
  return showModalBottomSheet<Map<String, String>?>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TotpFactorSheet(title: title, subtitle: subtitle),
  );
}

class _TotpFactorSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  const _TotpFactorSheet({required this.title, required this.subtitle});

  @override
  State<_TotpFactorSheet> createState() => _TotpFactorSheetState();
}

class _TotpFactorSheetState extends State<_TotpFactorSheet> {
  bool _useBackupCode = false;
  final _backupController = TextEditingController();
  String _code = '';

  @override
  void dispose() {
    _backupController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_useBackupCode) {
      final value = _backupController.text.trim();
      if (value.isEmpty) return;
      Navigator.of(context).pop({'backupCode': value});
    } else {
      if (_code.length != 6) return;
      Navigator.of(context).pop({'code': _code});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(widget.subtitle, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5)),
              const SizedBox(height: 20),
              if (_useBackupCode)
                TextField(
                  controller: _backupController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Backup code',
                    hintText: 'XXXX-XXXX',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                  onSubmitted: (_) => _submit(),
                )
              else
                Center(
                  child: OtpCodeField(
                    length: 6,
                    onCompleted: (code) => setState(() => _code = code),
                    onChanged: (code) => setState(() => _code = code),
                  ),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() {
                  _useBackupCode = !_useBackupCode;
                  _code = '';
                  _backupController.clear();
                }),
                child: Text(_useBackupCode ? 'Use my authenticator app instead' : 'Use a backup code instead'),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _submit, child: const Text('Confirm')),
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
