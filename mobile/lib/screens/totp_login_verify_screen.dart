import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/otp_code_field.dart';

/// Feature: TOTP two-factor authentication — the login-time step.
/// LoginScreen pushes this right after [AuthService.beginEmailLogin]
/// succeeds, when [AuthService.isTotpEnabled] says this account has 2FA
/// on, and BEFORE calling [AuthService.finishLogin] — same position in
/// the flow as the existing login-approval wait, so a wrong/missing
/// code never touches this device's local crypto state or claims the
/// account's active-device slot (see LoginScreen._login).
///
/// Returns `true` if a valid code/backup code was confirmed via
/// [AuthService.totpVerifyLogin], or `false` if the person cancelled —
/// LoginScreen treats a `false`/null result exactly like a denied
/// approval: it calls [AuthService.abortLogin] and signs this device
/// back out.
class TotpLoginVerifyScreen extends StatefulWidget {
  const TotpLoginVerifyScreen({super.key});

  @override
  State<TotpLoginVerifyScreen> createState() => _TotpLoginVerifyScreenState();
}

class _TotpLoginVerifyScreenState extends State<TotpLoginVerifyScreen> {
  final _authService = AuthService();
  final _otpKey = GlobalKey<OtpCodeFieldState>();
  final _backupController = TextEditingController();

  bool _useBackupCode = false;
  bool _verifying = false;
  OtpFieldStatus _status = OtpFieldStatus.idle;
  String? _error;

  @override
  void dispose() {
    _backupController.dispose();
    super.dispose();
  }

  Future<void> _verifyCode(String code) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await _authService.totpVerifyLogin(code: code);
      if (!mounted) return;
      setState(() => _status = OtpFieldStatus.success);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _status = OtpFieldStatus.error;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          _otpKey.currentState?.clear();
          setState(() => _status = OtpFieldStatus.idle);
        }
      });
    }
  }

  Future<void> _verifyBackupCode() async {
    if (_verifying) return;
    final value = _backupController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await _authService.totpVerifyLogin(backupCode: value);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Two-factor authentication'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.verified_user_outlined, size: 48, color: scheme.primary),
                  const SizedBox(height: 14),
                  Text(
                    _useBackupCode ? 'Enter a backup code' : 'Enter your 6-digit code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _useBackupCode
                        ? "One of the backup codes you saved when you turned this on."
                        : 'From your authenticator app, to finish signing in.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  if (_useBackupCode)
                    TextField(
                      controller: _backupController,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      textAlign: TextAlign.center,
                      enabled: !_verifying,
                      decoration: const InputDecoration(hintText: 'XXXX-XXXX'),
                      onSubmitted: (_) => _verifyBackupCode(),
                    )
                  else
                    Center(
                      child: OtpCodeField(
                        key: _otpKey,
                        length: 6,
                        status: _status,
                        enabled: !_verifying,
                        onCompleted: _verifyCode,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                    ),
                  const SizedBox(height: 20),
                  if (_useBackupCode)
                    FilledButton(
                      onPressed: _verifying ? null : _verifyBackupCode,
                      child: _verifying
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                            )
                          : const Text('Confirm'),
                    ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _verifying
                        ? null
                        : () => setState(() {
                              _useBackupCode = !_useBackupCode;
                              _error = null;
                              _backupController.clear();
                              _otpKey.currentState?.clear();
                            }),
                    child: Text(_useBackupCode ? 'Use my authenticator app instead' : "Can't access your authenticator app?"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
