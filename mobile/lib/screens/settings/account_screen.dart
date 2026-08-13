import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../../widgets/phone_otp_sheet.dart';
import 'forgot_password_screen.dart';

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
      _showErrorWithHelp('Could not change email. Check your password and try again.');
    }
  }

  Future<void> _changePhone() async {
    final newPhone = await _promptDialog(
      title: 'Change phone number',
      label: 'Phone number (e.g. +91XXXXXXXXXX)',
      initialValue: _phone,
      keyboardType: TextInputType.phone,
    );
    if (newPhone == null || newPhone.trim().isEmpty || newPhone.trim() == _phone) return;
    final trimmedPhone = newPhone.trim();

    final password = await _promptPassword('Confirm your current password to change your phone number.');
    if (password == null) return;

    try {
      await _authService.reauthenticate(password);
    } catch (e) {
      _showErrorWithHelp('Incorrect password.');
      return;
    }

    if (!mounted) return;
    final credential = await showPhoneOtpSheet(context, phoneNumber: trimmedPhone);
    if (credential == null) return;

    try {
      await _authService.linkAndSavePhoneNumber(credential: credential, phoneNumber: trimmedPhone);
      if (!mounted) return;
      setState(() => _phone = trimmedPhone);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number verified and updated')),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use' || e.code == 'provider-already-linked') {
        _showErrorWithHelp('This phone number is already linked to another account.');
      } else {
        _showErrorWithHelp(e.message ?? 'Could not update phone number.');
      }
    } catch (e) {
      _showErrorWithHelp('Could not update phone number.');
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
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('Forgot your password?'),
                  subtitle: const Text('Reset it via email link or phone OTP'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
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
