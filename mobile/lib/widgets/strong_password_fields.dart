import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/password_generator.dart';

/// Feature: shared password + confirm-password UI with show/hide toggles,
/// a "Suggest strong password" button (fills both fields, repeatable —
/// tap again for a different one), and a copy button. Used by
/// RegisterScreen's password step and ForgotPasswordScreen's OTP-based
/// reset step, so the same behavior and look is available in both
/// places instead of two separate hand-rolled versions.
class StrongPasswordFields extends StatefulWidget {
  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final String passwordLabel;
  final String confirmLabel;

  /// Called after every keystroke in either field, and after the
  /// generator fills them — lets the parent screen re-check
  /// length/match validity without this widget needing to know about
  /// that logic itself.
  final VoidCallback? onChanged;

  const StrongPasswordFields({
    super.key,
    required this.passwordController,
    required this.confirmController,
    this.passwordLabel = 'Password',
    this.confirmLabel = 'Confirm password',
    this.onChanged,
  });

  @override
  State<StrongPasswordFields> createState() => _StrongPasswordFieldsState();
}

class _StrongPasswordFieldsState extends State<StrongPasswordFields> {
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  void _suggest() {
    final generated = generateStrongPassword();
    widget.passwordController.text = generated;
    widget.confirmController.text = generated;
    setState(() {
      // Reveal both fields so the person can actually see what was
      // generated before they rely on the copy button — an invisible
      // "suggestion" isn't very useful.
      _obscurePassword = false;
      _obscureConfirm = false;
    });
    widget.onChanged?.call();
  }

  void _copy() {
    final pw = widget.passwordController.text;
    if (pw.isEmpty) return;
    Clipboard.setData(ClipboardData(text: pw));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password copied')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mismatch = widget.confirmController.text.isNotEmpty &&
        widget.confirmController.text != widget.passwordController.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.passwordController,
          obscureText: _obscurePassword,
          onChanged: (_) => widget.onChanged?.call(),
          decoration: InputDecoration(
            labelText: widget.passwordLabel,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.confirmController,
          obscureText: _obscureConfirm,
          onChanged: (_) => widget.onChanged?.call(),
          decoration: InputDecoration(
            labelText: widget.confirmLabel,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
        ),
        if (mismatch)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text("Passwords don't match", style: TextStyle(color: scheme.error, fontSize: 12.5)),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _suggest,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Suggest strong password'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _copy,
              tooltip: 'Copy password',
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      ],
    );
  }
}
