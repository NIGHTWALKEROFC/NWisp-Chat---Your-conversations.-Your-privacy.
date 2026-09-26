import 'package:flutter/material.dart';

/// Feature: Instagram-style "new email" + "confirm new email" pair, mirroring
/// StrongPasswordFields' password/confirm-password pattern elsewhere in the
/// app (RegisterScreen, ForgotPasswordScreen, AccountScreen's password
/// change). Used by AccountScreen's "Change email" flow so a typo in the new
/// address is caught before anything is sent, the same way a typo'd new
/// password is caught before it's saved.
class ConfirmEmailFields extends StatefulWidget {
  final TextEditingController emailController;
  final TextEditingController confirmController;
  final String emailLabel;
  final String confirmLabel;

  /// Called after every keystroke in either field — lets the parent screen
  /// re-check match/validity without this widget needing to know that
  /// logic itself (same contract as StrongPasswordFields.onChanged).
  final VoidCallback? onChanged;

  const ConfirmEmailFields({
    super.key,
    required this.emailController,
    required this.confirmController,
    this.emailLabel = 'New email address',
    this.confirmLabel = 'Confirm new email address',
    this.onChanged,
  });

  @override
  State<ConfirmEmailFields> createState() => _ConfirmEmailFieldsState();
}

class _ConfirmEmailFieldsState extends State<ConfirmEmailFields> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mismatch = widget.confirmController.text.isNotEmpty &&
        widget.confirmController.text.trim().toLowerCase() != widget.emailController.text.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.emailController,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          onChanged: (_) => widget.onChanged?.call(),
          decoration: InputDecoration(
            labelText: widget.emailLabel,
            prefixIcon: const Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.confirmController,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => widget.onChanged?.call(),
          decoration: InputDecoration(
            labelText: widget.confirmLabel,
            prefixIcon: const Icon(Icons.email_outlined),
          ),
        ),
        if (mismatch)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text("Email addresses don't match", style: TextStyle(color: scheme.error, fontSize: 12.5)),
          ),
      ],
    );
  }
}
