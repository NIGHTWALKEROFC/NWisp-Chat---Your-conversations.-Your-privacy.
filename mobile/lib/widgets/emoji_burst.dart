import 'dart:math';
import 'package:flutter/material.dart';

/// A layer that shows emojis floating up and fading out — the "burst" when
/// someone reacts to a story. Put it on top of the content (inside a Stack,
/// wrapped in IgnorePointer so it never blocks taps) and call
/// `burstKey.currentState?.burst('🔥')` to set one off:
///
///     final _burstKey = GlobalKey<EmojiBurstState>();
///     ...
///     Positioned.fill(child: IgnorePointer(child: EmojiBurst(key: _burstKey)))
///
/// Purely visual — it knows nothing about stories or messages.
class EmojiBurst extends StatefulWidget {
  const EmojiBurst({super.key});

  @override
  State<EmojiBurst> createState() => EmojiBurstState();
}

class _Particle {
  final int id;
  final String emoji;
  final double startX; // 0..1 across the width
  final double drift; // sideways sway in pixels
  final double size;
  final Duration duration;
  final Duration delay;
  const _Particle({
    required this.id,
    required this.emoji,
    required this.startX,
    required this.drift,
    required this.size,
    required this.duration,
    required this.delay,
  });
}

class EmojiBurstState extends State<EmojiBurst> {
  /// Never more than this many on screen at once, however fast someone taps.
  static const _maxParticles = 60;

  final _random = Random();
  final List<_Particle> _particles = [];
  int _nextId = 0;

  /// Sends [count] copies of [emoji] floating up from the bottom.
  void burst(String emoji, {int count = 14}) {
    setState(() {
      for (var i = 0; i < count; i++) {
        _particles.add(
          _Particle(
            id: _nextId++,
            emoji: emoji,
            startX: 0.12 + _random.nextDouble() * 0.76,
            drift: (_random.nextDouble() - 0.5) * 90,
            size: 26 + _random.nextDouble() * 26,
            duration: Duration(milliseconds: 1200 + _random.nextInt(900)),
            delay: Duration(milliseconds: _random.nextInt(260)),
          ),
        );
      }
      if (_particles.length > _maxParticles) {
        _particles.removeRange(0, _particles.length - _maxParticles);
      }
    });
  }

  void _remove(int id) {
    if (!mounted) return;
    setState(() => _particles.removeWhere((p) => p.id == id));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final p in _particles)
              _FloatingEmoji(
                key: ValueKey(p.id),
                particle: p,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                onDone: () => _remove(p.id),
              ),
          ],
        );
      },
    );
  }
}

class _FloatingEmoji extends StatefulWidget {
  final _Particle particle;
  final double width;
  final double height;
  final VoidCallback onDone;
  const _FloatingEmoji({
    super.key,
    required this.particle,
    required this.width,
    required this.height,
    required this.onDone,
  });

  @override
  State<_FloatingEmoji> createState() => _FloatingEmojiState();
}

class _FloatingEmojiState extends State<_FloatingEmoji> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.particle.duration);
    Future<void>.delayed(widget.particle.delay, () {
      if (mounted) _controller.forward();
    });
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.particle;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_controller.value);
        // Rises most of the way up, sways side to side, pops in at the start
        // and fades over the last third.
        final y = widget.height - 40 - t * widget.height * 0.8;
        final x = p.startX * widget.width + sin(t * pi * 2) * p.drift;
        final scale = _controller.value < 0.15 ? _controller.value / 0.15 : 1.0;
        final opacity = _controller.value < 0.65 ? 1.0 : (1 - (_controller.value - 0.65) / 0.35).clamp(0.0, 1.0);
        return Positioned(
          left: x - p.size / 2,
          top: y,
          child: Opacity(
            opacity: opacity.toDouble(),
            child: Transform.scale(
              scale: scale,
              child: Text(p.emoji, style: TextStyle(fontSize: p.size)),
            ),
          ),
        );
      },
    );
  }
}
