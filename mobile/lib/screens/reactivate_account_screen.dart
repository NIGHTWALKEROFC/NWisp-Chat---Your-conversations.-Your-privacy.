import 'package:flutter/material.dart';
import '../services/account_lifecycle_service.dart';
import '../services/auth_service.dart';

/// Shown by AuthGate instead of the normal app when this account's
/// accountStatus is 'self_disabled' (see AccountScreen's "Temporarily
/// deactivate account" action). Distinct from admin-driven suspension,
/// which will use a different status value and a different screen.
class ReactivateAccountScreen extends StatefulWidget {
  final VoidCallback onReactivated;
  const ReactivateAccountScreen({super.key, required this.onReactivated});

  @override
  State<ReactivateAccountScreen> createState() => _ReactivateAccountScreenState();
}

class _ReactivateAccountScreenState extends State<ReactivateAccountScreen> {
  bool _busy = false;

  Future<void> _reactivate() async {
    setState(() => _busy = true);
    try {
      await AccountLifecycleService.setSelfDisabled(false);
      widget.onReactivated();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reactivate. Check your connection and try again.')),
      );
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    // Leaves accountStatus as 'self_disabled' — signing out here is just
    // "not right now", not a change of mind about deactivating.
    await AuthService().logout();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_outline, size: 56, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Your account is deactivated',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  "You temporarily deactivated this account. Nothing was deleted — reactivate to "
                  "get back into your chats.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                if (_busy)
                  const CircularProgressIndicator()
                else ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _reactivate,
                      child: const Text('Reactivate my account'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _signOut, child: const Text('Sign out instead')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
