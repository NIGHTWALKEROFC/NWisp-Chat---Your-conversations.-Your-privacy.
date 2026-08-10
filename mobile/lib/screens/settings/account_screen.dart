import 'package:flutter/material.dart';
import '../../services/auth_service.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _authService = AuthService();
  String _email = '';
  String _phone = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final doc = await _authService.currentUserProfile();
    if (!mounted) return;
    setState(() {
      _email = _authService.currentUser?.email ?? '';
      _phone = (doc.data()?['phoneNumber'] as String?) ?? '';
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
      _showError('Could not change email. Check your password and try again.');
    }
  }

  Future<void> _changePhone() async {
    final newPhone = await _promptDialog(
      title: 'Change phone number',
      label: 'Phone number',
      initialValue: _phone,
      keyboardType: TextInputType.phone,
    );
    if (newPhone == null) return;
    try {
      await _authService.updatePhoneNumber(newPhone.trim());
      if (!mounted) return;
      setState(() => _phone = newPhone.trim());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number updated')),
      );
    } catch (e) {
      _showError('Could not update phone number.');
    }
  }

  Future<void> _changePassword() async {
    final currentPassword = await _promptPassword('Enter your current password.');
    if (currentPassword == null) return;
    final newPassword = await _promptPassword('Enter your new password (min 6 characters).');
    if (newPassword == null || newPassword.length < 6) {
      if (newPassword != null) _showError('Password must be at least 6 characters.');
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
      _showError('Could not change password. Check your current password and try again.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
                  leading: const Icon(Icons.phone_outlined),
                  title: const Text('Phone number'),
                  subtitle: Text(_phone.isEmpty ? 'Not set' : _phone),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePhone,
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Password'),
                  subtitle: const Text('••••••••'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePassword,
                ),
              ],
            ),
    );
  }
}
