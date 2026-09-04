import 'package:flutter/material.dart';
import '../../services/account_lifecycle_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/contact_developer_sheet.dart';
import 'account_security_screen.dart';
import 'delete_account_screen.dart';
import 'forgot_password_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _authService = AuthService();
  String _email = '';
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _email = _authService.currentUser?.email ?? '';
      _loading = false;
    });
  }

  Future<void> _changeEmail() async {
    final newEmail = await _promptDialog(
      title: 'Change email',
      label: 'New email address',
      initialValue: _email,
      keyboardType: TextInputType.emailAddress,
    );
    if (newEmail == null || newEmail.trim().isEmpty || newEmail == _email) return;

    final password = await _promptPassword('Confirm your current password to change your email.');
    if (password == null) return;

    try {
      await _authService.reauthenticate(password);
      await _authService.requestEmailChange(newEmail.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Check $newEmail for a link to confirm the change')),
      );
    } catch (e) {
      _showErrorWithHelp('Could not change email. Check your password and try again.');
    }
  }

  Future<void> _changePassword() async {
    final currentPassword = await _promptPassword('Enter your current password.');
    if (currentPassword == null) return;
    final newPassword = await _promptPassword('Enter your new password (min 6 characters).');
    if (newPassword == null || newPassword.length < 6) {
      if (newPassword != null) _showErrorWithHelp('Password must be at least 6 characters.');
      return;
    }
    try {
      await _authService.reauthenticate(currentPassword);
      await _authService.updatePassword(newPassword);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated')),
      );
    } catch (e) {
      _showErrorWithHelp("Could not change password. If you don't remember your current one, use "
          "'Forgot password?' below instead.");
    }
  }

  Future<void> _exportData() async {
    setState(() => _exporting = true);
    try {
      await AccountLifecycleService.exportAndShareUserData();
    } catch (e) {
      _showErrorWithHelp('Could not export your data. Please try again.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirmDeactivate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deactivate account?'),
        content: const Text(
          "Your account will be hidden and you won't be able to use NWisp until you log back in "
          "and reactivate it. This does NOT delete anything — your messages, contacts, and "
          "settings are all still there when you come back.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Deactivate')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AccountLifecycleService.setSelfDisabled(true);
      await _authService.logout();
      // Logging out flips AuthGate straight to LoginScreen, which tears
      // down this screen — no further setState needed on success.
    } catch (e) {
      _showErrorWithHelp('Could not deactivate your account. Please try again.');
    }
  }

  void _showErrorWithHelp(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Get help', onPressed: () => showContactDeveloperSheet(context)),
      ),
    );
  }

  Future<String?> _promptDialog({
    required String title,
    required String label,
    String initialValue = '',
    TextInputType? keyboardType,
  }) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: keyboardType,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptPassword(String message) {
    final controller = TextEditingController();
    bool obscure = true;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Confirm password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email'),
                  subtitle: Text(_email),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changeEmail,
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Password'),
                  subtitle: const Text('••••••••'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePassword,
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('Forgot your password?'),
                  subtitle: const Text('Reset it via email link'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Account security'),
                  subtitle: const Text('Active device, login activity, password history'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AccountSecurityScreen()),
                  ),
                ),
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Export your data'),
                  subtitle: const Text('Save a copy of your profile and account settings'),
                  trailing: _exporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _exporting ? null : _exportData,
                ),
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Temporarily deactivate account'),
                  subtitle: const Text('Hide your account until you log back in'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _confirmDeactivate,
                ),
                const Divider(height: 32),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
                  title: Text(
                    'Delete account',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  subtitle: const Text('Permanently delete your account and all its data'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
                  ),
                ),
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Contact the developer'),
                  subtitle: const Text('Trouble with any of the above? Get help directly.'),
                  onTap: () => showContactDeveloperSheet(context),
                ),
              ],
            ),
    );
  }
}
