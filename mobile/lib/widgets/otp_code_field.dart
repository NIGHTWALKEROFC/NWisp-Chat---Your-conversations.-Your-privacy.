import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the boxes should look like.
///  * [idle]    — normal, waiting for digits.
///  * [success] — every box fills GREEN (code was correct).
///  * [error]   — every box fills RED and shakes (code was wrong).
enum OtpFieldStatus { idle, success, error }

/// Telegram-style one-time-code entry: a row of separate boxes, one per
/// digit, that fill in as you type.
///
/// Under the boxes sits one invisible text field that does the real work, so
/// typing, backspace, pasting the whole code, and the keyboard's own
/// "paste code" suggestion all behave exactly like a normal field.
///
/// The screen decides what a finished code MEANS: this widget only calls
/// [onCompleted] once all digits are in, and the screen then sets [status] to
/// [OtpFieldStatus.success] or [OtpFieldStatus.error]. On error it shakes; the
/// screen usually calls [OtpCodeFieldState.clear] a moment later so the person
/// can try again.
class OtpCodeField extends StatefulWidget {
  final int length;
  final OtpFieldStatus status;
  final bool enabled;
  final ValueChanged<String> onCompleted;
  final ValueChanged<String>? onChanged;

  const OtpCodeField({
    super.key,
    required this.onCompleted,
    this.length = 6,
    this.status = OtpFieldStatus.idle,
    this.enabled = true,
    this.onChanged,
  });

  @override
  State<OtpCodeField> createState() => OtpCodeFieldState();
}

class OtpCodeFieldState extends State<OtpCodeField> with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant OtpCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == OtpFieldStatus.error && oldWidget.status != OtpFieldStatus.error) {
      _shake.forward(from: 0);
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  /// Empties every box (used by the screen after a wrong code).
  void clear() {
    _controller.clear();
    if (mounted) setState(() {});
  }

  /// Brings the keyboard up.
  void focus() => _focus.requestFocus();

  void _onTextChanged() {
    final text = _controller.text;
    widget.onChanged?.call(text);
    if (mounted) setState(() {});
    if (text.length == widget.length) widget.onCompleted(text);
  }

  Color _fill(ColorScheme scheme, bool isCurrent) {
    switch (widget.status) {
      case OtpFieldStatus.success:
        return const Color(0xFF2E9E5B);
      case OtpFieldStatus.error:
        return scheme.error;
      case OtpFieldStatus.idle:
        return isCurrent ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    }
  }

  Color _border(ColorScheme scheme, bool isCurrent) {
    switch (widget.status) {
      case OtpFieldStatus.success:
        return const Color(0xFF2E9E5B);
      case OtpFieldStatus.error:
        return scheme.error;
      case OtpFieldStatus.idle:
        return isCurrent ? scheme.primary : Colors.transparent;
    }
  }

  Color _digitColor(ColorScheme scheme) {
    return widget.status == OtpFieldStatus.idle ? scheme.onSurface : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = _controller.text;
    final locked = !widget.enabled || widget.status == OtpFieldStatus.success;

    final boxes = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < widget.length; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
            child: _buildBox(
              scheme: scheme,
              digit: i < text.length ? text[i] : '',
              isCurrent: _focus.hasFocus && widget.status == OtpFieldStatus.idle && i == min(text.length, widget.length - 1),
            ),
          ),
      ],
    );

    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // A quick left-right wobble that fades out.
        final t = _shake.value;
        final dx = sin(t * pi * 5) * 10 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: locked ? null : focus,
        child: Stack(
          alignment: Alignment.center,
          children: [
            boxes,
            // The real input. Invisible, but focusable and fully functional.
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  readOnly: locked,
                  keyboardType: TextInputType.number,
                  maxLength: widget.length,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBox({required ColorScheme scheme, required String digit, required bool isCurrent}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      width: 44,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _fill(scheme, isCurrent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border(scheme, isCurrent), width: 2),
      ),
      child: Text(
        digit,
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: _digitColor(scheme)),
      ),
    );
  }
}
