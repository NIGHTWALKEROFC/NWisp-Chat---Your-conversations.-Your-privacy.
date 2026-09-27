import 'package:flutter/material.dart';
import '../../services/account_lifecycle_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/breach_warning_dialog.dart';
import '../../widgets/confirm_email_fields.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../../widgets/strong_password_fields.dart';
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

  // ---- Change email (redesign) -----------------------------------------
  //
  // Instagram-style: "new email" + "confirm new email" are shown TOGETHER,
  // just like a "new password" + "confirm password" pair, so a typo in the
  // new address is caught before the person ever has to type their
  // password or wait for a confirmation email that will never arrive at
  // the address they actually meant. Only once the two match do we ask for
  // the current password (same reauthentication step as before — nothing
  // about how the change is actually applied server-side has changed).
  Future<void> _changeEmail() async {
    final newEmail = await _promptNewEmail();
    if (newEmail == null) return;

    final password = await _promptPassword('Confirm your current password to change your email.');
    if (password == null) return;

    try {
      await _authService.reauthenticate(password);
      await _authService.requestEmailChange(newEmail);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Check $newEmail for a link to confirm the change')),
      );
    } catch (e) {
      _showErrorWithHelp('Could not change email. Check your password and try again.');
    }
  }

  /// Shows the "new email" / "confirm new email" pair (see
  /// ConfirmEmailFields) and returns the validated, trimmed new address —
  /// or null if the person cancelled, left it unchanged, or the two
  /// fields didn't match.
  Future<String?> _promptNewEmail() async {
    final emailController = TextEditingController();
    final confirmController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final newEmail = emailController.text.trim();
            final confirmEmail = confirmController.text.trim();
            final looksValid = newEmail.contains('@') && newEmail.contains('.');
            final matches = confirmEmail.isNotEmpty && confirmEmail.toLowerCase() == newEmail.toLowerCase();
            final isUnchanged = newEmail.isNotEmpty && newEmail.toLowerCase() == _email.toLowerCase();
            return AlertDialog(
              title: const Text('Change email'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Current email: $_email', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 16),
                    ConfirmEmailFields(
                      emailController: emailController,
                      confirmController: confirmController,
                      onChanged: () => setDialogState(() {}),
                    ),
                    if (isUnchanged)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'That matches your current email address.',
                          style: TextStyle(color: Theme.of(dialogContext).colorScheme.error, fontSize: 12.5),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                FilledButton(
                  onPressed: looksValid && matches && !isUnchanged
                      ? () => Navigator.pop(dialogContext, newEmail)
                      : null,
                  child: const Text('Next'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      emailController.dispose();
      confirmController.dispose();
    }
  }

  // ---- Change password (redesign) --------------------------------------
  //
  // Instagram-style: current password first (its own, separate step — you
  // shouldn't see the "new password" fields until you've proven you're
  // allowed to set one), THEN "new password" + "confirm new password"
  // shown together, reusing the exact same StrongPasswordFields widget
  // signup/reset already use, instead of two sequential single-field
  // prompts with no way to compare them side by side.
  Future<void> _changePassword() async {
    final currentPassword = await _promptPassword('Enter your current password.');
    if (currentPassword == null) return;

    final newPassword = await _promptNewPassword();
    if (newPassword == null) return;

    final ok = await confirmPasswordNotBreached(context, newPassword);
    if (!ok || !mounted) return;
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

  /// Shows the "new password" / "confirm new password" pair (see
  /// StrongPasswordFields — same widget used at signup) and returns the
  /// validated new password, or null if cancelled or too short.
  Future<String?> _promptNewPassword() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matches = passwordController.text.isNotEmpty && passwordController.text == confirmController.text;
            final longEnough = passwordController.text.length >= 6;
            return AlertDialog(
              title: const Text('Choose a new password'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StrongPasswordFields(
                      passwordController: passwordController,
                      confirmController: confirmController,
                      passwordLabel: 'New password',
                      confirmLabel: 'Confirm new password',
                      onChanged: () => setDialogState(() {}),
                    ),
                    if (passwordController.text.isNotEmpty && !longEnough)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Must be at least 6 characters.',
                          style: TextStyle(color: Theme.of(dialogContext).colorScheme.error, fontSize: 12.5),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                FilledButton(
                  onPressed: matches && longEnough ? () => Navigator.pop(dialogContext, passwordController.text) : null,
                  child: const Text('Next'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      passwordController.dispose();
      confirmController.dispose();
    }
  }

  Future<void> _exportData() async {
    final password = await _promptExportPassword();
    if (password == null) return;
    setState(() => _exporting = true);
    try {
      await AccountLifecycleService.exportAndShareUserData(password);
    } catch (e) {
      _showErrorWithHelp('Could not export your data. Please try again.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Feature: password-protected export. Uses the same
  /// StrongPasswordFields widget (generate/copy/show-hide) as signup and
  /// password reset — setting an export password is exactly that same
  /// "pick a strong password" moment. Returns null if cancelled.
  Future<String?> _promptExportPassword() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matches = passwordController.text.isNotEmpty && passwordController.text == confirmController.text;
            return AlertDialog(
              title: const Text('Protect your export'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      "Choose a password to encrypt this file. Without it, the file is unreadable — "
                      "so save this password somewhere safe, you'll need it to open the export later.",
                    ),
                    const SizedBox(height: 16),
                    StrongPasswordFields(
                      passwordController: passwordController,
                      confirmController: confirmController,
                      passwordLabel: 'Export password',
                      confirmLabel: 'Confirm export password',
                      onChanged: () => setDialogState(() {}),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                FilledButton(
                  onPressed: matches && passwordController.text.length >= 6
                      ? () => Navigator.pop(dialogContext, passwordController.text)
                      : null,
                  child: const Text('Export'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      passwordController.dispose();
      confirmController.dispose();
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

  /// Instagram/WhatsApp-style section label — small, muted, left-aligned
  /// above a group of related rows. Used to break the screen into clearly
  /// separated groups instead of one long undifferentiated list.
  Widget _sectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ---- Login info ------------------------------------------------
                _sectionHeader(context, 'Login info'),
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
                    // Bug fix: this screen already knows the signed-in
                    // account's email (_email, loaded in _load() above) —
                    // AccountSecurityScreen's own "Not sure this was you?"
                    // entry point already does this correctly by passing
                    // knownEmail, this row just hadn't been updated to
                    // match. Passing it here does the same thing
                    // ForgotPasswordScreen already supports: it shows
                    // "We'll email a code/link to <email>" and skips
                    // straight past the identifier text field entirely,
                    // instead of asking someone to re-type an email
                    // the app already has.
                    MaterialPageRoute(builder: (_) => ForgotPasswordScreen(knownEmail: _email)),
                  ),
                ),

                // ---- Security ----------------------------------------------------
                _sectionHeader(context, 'Security'),
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

                // ---- Your information ---------------------------------------------
                _sectionHeader(context, 'Your information'),
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

                // ---- Account management -------------------------------------------
                _sectionHeader(context, 'Account management'),
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Temporarily deactivate account'),
                  subtitle: const Text('Hide your account until you log back in'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _confirmDeactivate,
                ),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: scheme.error),
                  title: Text('Delete account', style: TextStyle(color: scheme.error)),
                  subtitle: const Text('Permanently delete your account and all its data'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
                  ),
                ),

                // ---- Support -----------------------------------------------------
                _sectionHeader(context, 'Support'),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Contact the developer'),
                  subtitle: const Text('Trouble with any of the above? Get help directly.'),
                  onTap: () => showContactDeveloperSheet(context),
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }
}
