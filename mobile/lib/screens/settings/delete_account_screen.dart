import 'package:flutter/material.dart';
import '../../services/account_lifecycle_service.dart';
import '../../widgets/contact_developer_sheet.dart';

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  static const _confirmWord = 'DELETE';

  final _confirmController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _confirmController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_deleting &&
      _confirmController.text.trim() == _confirmWord &&
      _passwordController.text.isNotEmpty;

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await AccountLifecycleService.deleteAccount(_passwordController.text);
      // Deleting the Firebase Auth user fires authStateChanges — AuthGate
      // is already listening and drops back to LoginScreen on its own;
      // nothing else needs to happen here on success.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = 'Could not delete your account. Check your password and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: AbsorbPointer(
        absorbing: _deleting,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error, size: 40),
              const SizedBox(height: 12),
              Text('This is permanent', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Deleting your account permanently removes your profile, your settings, and any '
                'in-transit messages still waiting to be delivered, and wipes every bit of local '
                'data this device has for this account. This cannot be undone.',
              ),
              const SizedBox(height: 24),
              Text('Type $_confirmWord to confirm', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmController,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: _confirmWord,
                ),
              ),
              const SizedBox(height: 16),
              Text('Confirm your password', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: scheme.error),
                  onPressed: _canSubmit ? _delete : null,
                  child: _deleting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Permanently delete my account'),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: () => showContactDeveloperSheet(context),
                  icon: const Icon(Icons.support_agent_outlined, size: 16),
                  label: const Text('Need help instead?'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
