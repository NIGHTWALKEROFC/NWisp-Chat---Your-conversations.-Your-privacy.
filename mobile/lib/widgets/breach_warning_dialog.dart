import 'package:flutter/material.dart';
import '../utils/password_breach_checker.dart';

/// Feature: breached-password warning, shared by the signup, password-
/// reset, and change-password screens so all three behave identically.
///
/// Checks [password] and, if it's been seen in a known data breach,
/// shows a dialog explaining that with two choices: go back and pick a
/// different password, or continue anyway. Deliberately a WARNING, not
/// a hard block — the account owner's own password is their choice;
/// this just makes sure that choice is an informed one.
///
/// Returns true if the caller should proceed (either the password
/// wasn't found in any breach, or the person explicitly chose "Use it
/// anyway"). Returns false if they chose to go pick a different one —
/// the caller should just do nothing further in that case (stay on the
/// same screen).
Future<bool> confirmPasswordNotBreached(BuildContext context, String password) async {
  final count = await checkPasswordBreachCount(password);
  if (count <= 0) return true;
  if (!context.mounted) return false;

  final countLabel = count == 1 ? 'once' : (count < 1000 ? '$count times' : 'many times');

  final choice = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: Theme.of(dialogContext).colorScheme.error),
      title: const Text('This password has been seen before'),
      content: Text(
        'This password has appeared in known data breaches $countLabel. '
        "That doesn't mean YOUR account was breached — it means other people have used this "
        'exact password before, which makes it easier to guess. We recommend choosing a '
        'different one.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Use a different password'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Continue anyway'),
        ),
      ],
    ),
  );
  return choice ?? false;
}
