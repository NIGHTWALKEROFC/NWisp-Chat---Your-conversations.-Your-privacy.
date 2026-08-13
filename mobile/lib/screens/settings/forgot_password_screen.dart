import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/app_lock_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/contact_developer_sheet.dart';
import '../../widgets/phone_otp_sheet.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final bool alsoResetAppLock;
  const ForgotPasswordScreen({super.key, this.alsoResetAppLock = false});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> with SingleTickerProviderStateMixin {
  final _authService = AuthService();
  final _db = FirebaseFirestore.instance;
  late final TabController _tabController = TabController(length: 2, vsync: this);

  final _emailController = TextEditingController();
  bool _sendingEmail = false;
  bool _emailSent = false;
  String? _emailError;

  final _phoneController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _checkingPhone = false;
  bool _phoneVerified = false;
  bool _settingPassword = false;
  String? _phoneError;

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _sendingEmail = true;
      _emailError = null;
    });
    try {
      await _authService.sendPasswordResetEmail(email);
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailSent = true;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailError = e.message ?? 'Could not send reset email';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingEmail = false;
        _emailError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _startPhoneReset() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;
    setState(() {
      _checkingPhone = true;
      _phoneError = null;
    });
    try {
      final match = await _db.collection('users').where('phoneNumber', isEqualTo: phone).limit(1).get();
      if (match.docs.isEmpty) {
        if (!mounted) return;
        setState(() {
          _checkingPhone = false;
          _phoneError = "No account uses this phone number, or it hasn't been verified yet.";
        });
        return;
      }

      final credential = await showPhoneOtpSheet(context, phoneNumber: phone);
      if (!mounted) return;
      setState(() => _checkingPhone = false);
      if (credential == null) return;

      await _authService.signInWithPhoneCredential(credential);
      if (!mounted) return;
      setState(() => _phoneVerified = true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingPhone = false;
        _phoneError = e.message ?? 'Verification failed';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingPhone = false;
        _phoneError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _setNewPassword() async {
    final newPassword = _newPasswordController.text;
    if (newPassword.length < 6) {
      setState(() => _phoneError = 'Password must be at least 6 characters');
      return;
    }
    setState(() {
      _settingPassword = true;
      _phoneError = null;
    });
    try {
      await _authService.updatePassword(newPassword);
      if (widget.alsoResetAppLock) {
        await AppLockService.resetAfterAccountVerification();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated')));
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _settingPassword = false;
        _phoneError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset password'),
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: 'Email link'), Tab(text: 'Phone OTP')]),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text("We'll email you a secure link to set a new password."),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  enabled: !_emailSent,
                  decoration: const InputDecoration(labelText: 'Account email', border: OutlineInputBorder()),
                ),
                if (_emailError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_emailError!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 16),
                if (_emailSent)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.mark_email_read_outlined, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Check your inbox for a reset link. It may take a minute to arrive.',
                            style: TextStyle(color: scheme.onPrimaryContainer),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  FilledButton(
                    onPressed: _sendingEmail ? null : _sendResetEmail,
                    child: _sendingEmail
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Send reset link'),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_phoneVerified) ...[
                  const Text(
                    "We'll text a one-time code to your account's phone number. "
                    "This only works if a phone number has already been added and verified in Account settings.",
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone number',
                      hintText: '+91XXXXXXXXXX',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_phoneError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_phoneError!, style: TextStyle(color: scheme.error)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _checkingPhone ? null : _startPhoneReset,
                    child: _checkingPhone
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Send code'),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Icon(Icons.verified_outlined, color: scheme.primary),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Phone verified. Set a new password below.')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _newPasswordController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'New password', border: OutlineInputBorder()),
                  ),
                  if (_phoneError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_phoneError!, style: TextStyle(color: scheme.error)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _settingPassword ? null : _setNewPassword,
                    child: _settingPassword
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Update password'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextButton.icon(
            onPressed: () => showContactDeveloperSheet(context),
            icon: const Icon(Icons.support_agent_outlined, size: 18),
            label: const Text('Still stuck? Contact the developer'),
          ),
        ),
      ),
    );
  }
}
