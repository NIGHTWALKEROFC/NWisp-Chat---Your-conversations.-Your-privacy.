import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';

Future<PhoneAuthCredential?> showPhoneOtpSheet(BuildContext context, {required String phoneNumber}) {
  return showModalBottomSheet<PhoneAuthCredential>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PhoneOtpSheet(phoneNumber: phoneNumber),
  );
}

class _PhoneOtpSheet extends StatefulWidget {
  final String phoneNumber;
  const _PhoneOtpSheet({required this.phoneNumber});

  @override
  State<_PhoneOtpSheet> createState() => _PhoneOtpSheetState();
}

class _PhoneOtpSheetState extends State<_PhoneOtpSheet> {
  final _authService = AuthService();
  final _codeController = TextEditingController();
  String? _verificationId;
  bool _sending = true;
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sendCode();
  }

  Future<void> _sendCode() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _authService.startPhoneVerification(
        phoneNumber: widget.phoneNumber,
        onCodeSent: (id) {
          if (!mounted) return;
          setState(() {
            _verificationId = id;
            _sending = false;
          });
        },
        onFailed: (message) {
          if (!mounted) return;
          setState(() {
            _sending = false;
            _error = message;
          });
        },
        onAutoVerified: (credential) {
          if (!mounted) return;
          Navigator.pop(context, credential);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _verify() async {
    final id = _verificationId;
    final code = _codeController.text.trim();
    if (id == null || code.length < 4) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final credential = _authService.resolvePhoneCode(verificationId: id, smsCode: code);
      if (!mounted) return;
      Navigator.pop(context, credential);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = 'Incorrect code. Try again.';
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Verify ${widget.phoneNumber}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            _sending ? 'Sending a code by SMS…' : 'Enter the 6-digit code we sent you.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (_sending)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else ...[
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Verification code', border: OutlineInputBorder()),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _verifying ? null : _verify,
              child: _verifying
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Verify'),
            ),
            TextButton(onPressed: _sending ? null : _sendCode, child: const Text('Resend code')),
          ],
        ],
      ),
    );
  }
}
