import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/device_session_service.dart';

/// Shown on the OLD/active device — either pushed live the instant a new
/// login requests approval (see main.dart's watchPendingApprovalRequest
/// listener, while this device is in the foreground) or opened by tapping
/// the send-login-approval-push notification (background/killed state —
/// see main.dart's notification-tap handling). Both go through
/// main.dart's _presentLoginApproval, which guarantees only ONE of these
/// screens exists per request.
class LoginApprovalScreen extends StatefulWidget {
  final String uid;
  final String requestId;
  final String deviceLabel;
  final String? location;

  /// Feature: number matching. The number the NEW phone is showing. When it's
  /// present the person must tap it out of three choices; when it's null (a
  /// request from an older app build) the screen falls back to plain
  /// Accept / Deny.
  final int? matchNumber;

  const LoginApprovalScreen({
    super.key,
    required this.uid,
    required this.requestId,
    required this.deviceLabel,
    this.location,
    this.matchNumber,
  });

  @override
  State<LoginApprovalScreen> createState() => _LoginApprovalScreenState();
}

class _LoginApprovalScreenState extends State<LoginApprovalScreen> {
  bool _busy = false;
  bool _done = false;
  bool _approved = false;
  // The request was answered somewhere else, or it expired, while this
  // screen was open — nothing left to decide.
  bool _stale = false;
  bool _closing = false;
  // They tapped a number that wasn't the one on the new phone.
  bool _wrongNumber = false;
  StreamSubscription<String>? _statusSub;

  /// The real number plus two decoys, shuffled once so the order doesn't
  /// change on rebuild. All three look identical, so which one is right can't
  /// be guessed from how the buttons look.
  late final List<int> _options = _buildOptions();

  List<int> _buildOptions() {
    final correct = widget.matchNumber;
    if (correct == null) return const [];
    final rng = Random.secure();
    final options = <int>{correct};
    while (options.length < 3) {
      options.add(10 + rng.nextInt(90));
    }
    return options.toList()..shuffle(rng);
  }

  @override
  void initState() {
    super.initState();
    _statusSub = DeviceSessionService.instance.watchApprovalStatus(widget.uid, widget.requestId).listen(
      (status) {
        // Ignore our own answer coming back to us (_busy while we write it,
        // _done once it's recorded) — only react to it changing underneath us.
        if (!mounted || _busy || _done) return;
        if (status != 'pending') setState(() => _stale = true);
      },
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    // Let another path show this request again only if it's somehow still
    // pending (e.g. this screen was dismissed without answering).
    DeviceSessionService.instance.unmarkApprovalPresented(widget.requestId);
    super.dispose();
  }

  /// Picking the matching number approves; picking any other number DENIES —
  /// a wrong number means they aren't looking at the phone that's logging in.
  void _pickNumber(int picked) {
    final correct = picked == widget.matchNumber;
    _respond(correct, wrongNumber: !correct);
  }

  Future<void> _respond(bool approve, {bool wrongNumber = false}) async {
    // BUGFIX: a fast double-tap on Accept used to start two answers. The
    // guard runs BEFORE anything async, and the transaction underneath
    // (DeviceSessionService.respondToLoginApproval) also refuses to answer a
    // request that has already been answered.
    if (_busy || _done || _stale) return;
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
        _wrongNumber = wrongNumber;
        _busy = false;
      });
    } on LoginApprovalAlreadyHandled {
      if (!mounted) return;
      setState(() {
        _stale = true;
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

  void _close() {
    if (_closing) return; // one tap closes it; extra taps do nothing
    _closing = true;
    Navigator.of(context).maybePop();
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
            child: _done
                ? _buildDone(scheme)
                : (_stale ? _buildStale(scheme) : _buildPrompt(scheme)),
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
          _approved ? 'Login approved.' : (_wrongNumber ? "That number doesn't match — login denied." : 'Login denied.'),
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        if (_wrongNumber)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              "If you didn't just try to sign in on another device, someone may know your password — change it now.",
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        if (_approved)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'The new device is signing in now, and this phone will be signed out.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _close, child: const Text('Done')),
      ],
    );
  }

  Widget _buildStale(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history_toggle_off, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          'This request is no longer waiting',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'It was already answered, cancelled, or it expired.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _close, child: const Text('Close')),
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
        const SizedBox(height: 8),
        Text(
          'Approving lets the new device in and signs this phone out.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
        ),
        const SizedBox(height: 24),
        if (_busy)
          const CircularProgressIndicator()
        else if (_options.isNotEmpty) ...[
          // Feature: number matching.
          Text(
            'Tap the number shown on the new device',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final n in _options)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    width: 84,
                    height: 64,
                    child: FilledButton.tonal(
                      onPressed: () => _pickNumber(n),
                      child: Text('$n', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: () => _respond(false), child: const Text("This isn't me — deny")),
        ] else
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
