import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/media_vault_service.dart';
import '../../services/screenshot_guard_service.dart';

/// Feature: locked media vault — one PIN entry screen used for every PIN
/// step in the vault: creating the PIN, confirming it, unlocking, changing
/// it, and confirming a delete.
///
/// It doesn't decide what's right or wrong itself. When the person presses
/// Continue it hands the digits to [onSubmit], which returns an error message
/// to show, or null to accept — in which case this screen closes and returns
/// the digits.
///
/// If [footerLabel] / [onFooter] are given (used for "Forgot PIN?"), a text
/// button appears under the field. When [onFooter] returns true the screen
/// closes with [footerDoneResult], meaning "that flow finished the job".
class VaultPinScreen extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onSubmit;
  final String submitLabel;
  final String? footerLabel;
  final Future<bool> Function(BuildContext context)? onFooter;

  static const footerDoneResult = '__footer_done__';

  const VaultPinScreen({
    super.key,
    required this.title,
    required this.onSubmit,
    this.subtitle,
    this.submitLabel = 'Continue',
    this.footerLabel,
    this.onFooter,
  });

  @override
  State<VaultPinScreen> createState() => _VaultPinScreenState();
}

class _VaultPinScreenState extends State<VaultPinScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The PIN being typed must never end up in a screenshot or the
    // recent-apps preview.
    ScreenshotGuardService.acquire();
  }

  @override
  void dispose() {
    _controller.dispose();
    ScreenshotGuardService.release();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final pin = _controller.text.trim();
    if (pin.length < MediaVaultService.minPinLength) {
      setState(() => _error = 'Enter at least ${MediaVaultService.minPinLength} digits.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await widget.onSubmit(pin);
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context, pin);
      return;
    }
    setState(() {
      _busy = false;
      _error = problem;
      _controller.clear();
    });
  }

  Future<void> _footer() async {
    final onFooter = widget.onFooter;
    if (onFooter == null || _busy) return;
    final done = await onFooter(context);
    if (done && mounted) Navigator.pop(context, VaultPinScreen.footerDoneResult);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.enhanced_encryption_outlined, size: 52, color: scheme.primary),
                const SizedBox(height: 16),
                Text(widget.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                if (widget.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      widget.subtitle!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: MediaVaultService.maxPinLength,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  // A PIN should never be learned or suggested by a keyboard.
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(counterText: '', labelText: 'PIN'),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(widget.submitLabel),
                  ),
                ),
                if (widget.footerLabel != null && widget.onFooter != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton(onPressed: _footer, child: Text(widget.footerLabel!)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
