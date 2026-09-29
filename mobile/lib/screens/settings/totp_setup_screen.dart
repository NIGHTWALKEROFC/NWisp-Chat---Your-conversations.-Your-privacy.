import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/device_session_service.dart';
import '../../widgets/otp_code_field.dart';
import '../../widgets/totp_factor_sheet.dart';
import 'totp_backup_codes_screen.dart';

/// Feature: TOTP two-factor authentication + one-time backup codes.
/// Reached from Account security > "Two-factor authentication". Handles
/// both enabling (QR scan + confirm code + reveal backup codes) and
/// managing an already-enabled setup (turn off, regenerate codes).
///
/// Talks to five Edge Functions via AuthService (totpEnrollStart,
/// totpEnrollConfirm, totpDisable, totpRegenerateBackupCodes) and keeps
/// this account's `users/{uid}/private/profile.totpEnabled` Firestore
/// flag in sync — that's the flag LoginScreen checks to decide whether
/// to ask for a code during sign-in.
enum _EnrollStep { none, scanning, confirming }

class TotpSetupScreen extends StatefulWidget {
  const TotpSetupScreen({super.key});

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final _authService = AuthService();
  late Future<bool> _enabledFuture;

  _EnrollStep _step = _EnrollStep.none;
  String? _pendingSecret;
  String? _pendingOtpauthUri;
  bool _busy = false;
  String? _error;
  final _confirmOtpKey = GlobalKey<OtpCodeFieldState>();
  OtpFieldStatus _confirmStatus = OtpFieldStatus.idle;

  String get _uid => _authService.currentUserId!;

  @override
  void initState() {
    super.initState();
    _enabledFuture = _authService.isTotpEnabled(_uid);
  }

  void _refresh() {
    setState(() {
      _step = _EnrollStep.none;
      _pendingSecret = null;
      _pendingOtpauthUri = null;
      _error = null;
      _enabledFuture = _authService.isTotpEnabled(_uid);
    });
  }

  Future<void> _startEnroll() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _authService.totpEnrollStart();
      if (!mounted) return;
      setState(() {
        _pendingSecret = data['secret'] as String;
        _pendingOtpauthUri = data['otpauthUri'] as String;
        _step = _EnrollStep.scanning;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _confirmEnroll(String code) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final backupCodes = await _authService.totpEnrollConfirm(code);
      await _authService.setTotpEnabledFlag(_uid, true);
      // NWisp Chat notice + push. A failure here must never undo or hide a
      // successful enrollment, so it's swallowed.
      try {
        await DeviceSessionService.instance.logTotpChanged(_uid, enabled: true);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmStatus = OtpFieldStatus.success;
      });
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TotpBackupCodesScreen(codes: backupCodes, isInitialSetup: true)),
      );
      if (mounted) _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmStatus = OtpFieldStatus.error;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          _confirmOtpKey.currentState?.clear();
          setState(() => _confirmStatus = OtpFieldStatus.idle);
        }
      });
    }
  }

  Future<void> _disable() async {
    final factor = await showTotpFactorSheet(
      context,
      title: 'Turn off two-factor authentication',
      subtitle: 'Enter your current code to confirm.',
    );
    if (factor == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _authService.totpDisable(code: factor['code'], backupCode: factor['backupCode']);
      await _authService.setTotpEnabledFlag(_uid, false);
      try {
        await DeviceSessionService.instance.logTotpChanged(_uid, enabled: false);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _busy = false);
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Two-factor authentication is now off')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _regenerateBackupCodes() async {
    final factor = await showTotpFactorSheet(
      context,
      title: 'Regenerate backup codes',
      subtitle: 'Enter your current code to confirm. Your old backup codes will stop working.',
    );
    if (factor == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await _authService.totpRegenerateBackupCodes(code: factor['code'], backupCode: factor['backupCode']);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TotpBackupCodesScreen(codes: codes)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _copySecret() async {
    if (_pendingSecret == null) return;
    await Clipboard.setData(ClipboardData(text: _pendingSecret!));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Secret copied')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Two-factor authentication')),
      body: _step != _EnrollStep.none ? _buildEnrollFlow(scheme) : _buildStatus(scheme),
    );
  }

  Widget _buildStatus(ColorScheme scheme) {
    return FutureBuilder<bool>(
      future: _enabledFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final enabled = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(enabled ? Icons.verified_user : Icons.shield_outlined, size: 44, color: enabled ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              enabled ? 'Two-factor authentication is ON' : 'Two-factor authentication is OFF',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              enabled
                  ? "You'll need a code from your authenticator app (or a backup code) every time you sign in on a new device."
                  : 'Add an extra step at sign-in using an authenticator app like Google Authenticator, Authy, or 1Password.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            if (!enabled)
              FilledButton.icon(
                onPressed: _busy ? null : _startEnroll,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_moderator_outlined),
                label: const Text('Turn on two-factor authentication'),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _regenerateBackupCodes,
                icon: const Icon(Icons.refresh),
                label: const Text('Regenerate backup codes'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _disable,
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.remove_moderator_outlined),
                label: const Text('Turn off two-factor authentication'),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildEnrollFlow(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Scan this QR code',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'Using Google Authenticator, Authy, 1Password, or any other authenticator app.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(
              data: _pendingOtpauthUri ?? '',
              version: QrVersions.auto,
              size: 200,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: _copySecret,
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: Text("Can't scan? Copy setup key"),
          ),
        ),
        if (_pendingSecret != null)
          Center(
            child: SelectableText(
              _pendingSecret!,
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5, fontSize: 13),
            ),
          ),
        const SizedBox(height: 28),
        Text(
          'Enter the 6-digit code',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'From the app, to confirm setup.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
        ),
        const SizedBox(height: 16),
        Center(
          child: OtpCodeField(
            key: _confirmOtpKey,
            length: 6,
            status: _confirmStatus,
            enabled: !_busy,
            onCompleted: _confirmEnroll,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(child: Text(_error!, style: TextStyle(color: scheme.error))),
          ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: _busy ? null : _refresh,
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}
