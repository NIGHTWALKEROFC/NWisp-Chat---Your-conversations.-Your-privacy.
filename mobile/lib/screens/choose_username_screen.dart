import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';

/// Shown once to an account that has no username (accounts created while the
/// old sign-up bug existed). Without a username the account can't be found by
/// search or QR code and shows as "Unknown" to everyone else.
class ChooseUsernameScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ChooseUsernameScreen({super.key, required this.onDone});

  @override
  State<ChooseUsernameScreen> createState() => _ChooseUsernameScreenState();
}

class _LowerCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toLowerCase());
}

class _ChooseUsernameScreenState extends State<ChooseUsernameScreen> {
  final _auth = AuthService();
  final _controller = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;
  bool _checking = false;
  bool? _available;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final name = value.trim().toLowerCase();
    setState(() {
      _error = null;
      _available = null;
    });
    if (name.length < 3 || !RegExp(r'^[a-z0-9_]+$').hasMatch(name)) {
      setState(() => _checking = false);
      return;
    }
    if (AuthService.isBotStyleUsername(name)) {
      setState(() {
        _checking = false;
        _error = AuthService.botNameMessage;
      });
      return;
    }
    setState(() => _checking = true);
    final id = ++_requestId;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final ok = await _auth.isUsernameAvailable(name);
      if (!mounted || id != _requestId) return;
      setState(() {
        _checking = false;
        _available = ok;
      });
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _auth.claimUsername(_controller.text);
      if (!mounted) return;
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = _controller.text.trim().toLowerCase();
    final valid = name.length >= 3 && RegExp(r'^[a-z0-9_]+$').hasMatch(name);
    final canSave = valid && _available == true && !_saving;

    Widget status;
    if (_checking) {
      status = const Text('Checking availability…');
    } else if (_available == true) {
      status = Text('Username available', style: TextStyle(color: Colors.green.shade600));
    } else if (_available == false) {
      status = Text('Already taken', style: TextStyle(color: scheme.error));
    } else if (name.isNotEmpty && !valid) {
      status = Text('At least 3 characters — lowercase letters, numbers and underscores only',
          style: TextStyle(color: scheme.error, fontSize: 12.5));
    } else {
      status = const SizedBox.shrink();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Choose your username'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.badge_outlined, size: 52, color: scheme.primary),
              const SizedBox(height: 14),
              Text('One last step', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                "Your account doesn't have a username yet, so other people can't find you or scan your QR code. "
                'Pick one now — this is how people find and message you.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                autofocus: true,
                inputFormatters: [_LowerCase()],
                onChanged: _onChanged,
                decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
              ),
              const SizedBox(height: 8),
              status,
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                    : const Text('Save username'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
