import 'package:flutter/material.dart';
import '../services/device_session_service.dart';

/// Shown on the OLD/active device — either pushed live the instant a new
/// login requests approval (see main.dart's watchPendingApprovalRequest
/// listener, while this device is in the foreground) or opened by tapping
/// the send-login-approval-push notification (background/killed state —
/// see main.dart's notification-tap handling).
class LoginApprovalScreen extends StatefulWidget {
  final String uid;
  final String requestId;
  final String deviceLabel;
  final String? location;

  const LoginApprovalScreen({
    super.key,
    required this.uid,
    required this.requestId,
    required this.deviceLabel,
    this.location,
  });

  @override
  State<LoginApprovalScreen> createState() => _LoginApprovalScreenState();
}

class _LoginApprovalScreenState extends State<LoginApprovalScreen> {
  bool _busy = false;
  bool _done = false;
  bool _approved = false;

  Future<void> _respond(bool approve) async {
    setState(() => _busy = true);
    try {
      await DeviceSessionService.instance.respondToLoginApproval(
        uid: widget.uid,
        requestId: widget.requestId,
        approve: approve,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _approved = approve;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not respond. Check your connection and try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New login request')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _done ? _buildDone(scheme) : _buildPrompt(scheme),
          ),
        ),
      ),
    );
  }

  Widget _buildDone(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _approved ? Icons.check_circle_outline : Icons.block,
          size: 48,
          color: _approved ? Colors.green : scheme.error,
        ),
        const SizedBox(height: 16),
        Text(
          _approved ? 'Login approved.' : 'Login denied.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }

  Widget _buildPrompt(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.phonelink_lock, size: 48, color: scheme.primary),
        const SizedBox(height: 16),
        Text(
          'A new login is waiting for your approval',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(widget.deviceLabel, style: Theme.of(context).textTheme.titleMedium),
        if (widget.location != null)
          Text(widget.location!, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Text(
          "If this wasn't you, deny it and consider changing your password.",
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (_busy)
          const CircularProgressIndicator()
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(onPressed: () => _respond(false), child: const Text('Deny')),
              const SizedBox(width: 16),
              FilledButton(onPressed: () => _respond(true), child: const Text('Accept')),
            ],
          ),
      ],
    );
  }
}
