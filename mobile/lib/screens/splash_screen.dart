import 'package:flutter/material.dart';
import '../widgets/nwisp_ui.dart';

/// Shown while the app is getting ready (reading saved settings and the
/// sign-in state) instead of a bare spinner. Purely visual — it has no
/// timer of its own, so it never makes startup slower: it disappears the
/// moment AuthGate has what it needs.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: NwispBackdrop(
        child: Stack(
          children: [
            // Mountains + lake at the bottom, like the design.
            const Positioned(left: 0, right: 0, bottom: 0, height: 300, child: _Landscape()),
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  const NwispLogo(size: 96),
                  const SizedBox(height: 18),
                  const NwispWordmark(fontSize: 34),
                  const SizedBox(height: 12),
                  Text(
                    'Your conversations.\nYour privacy.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.85), fontSize: 16, height: 1.4),
                  ),
                  const Spacer(flex: 4),
                  SizedBox(
                    width: 140,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        color: scheme.primary,
                        backgroundColor: scheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Connecting securely...', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Landscape extends StatelessWidget {
  const _Landscape();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (!dark) return const SizedBox.shrink();
    return CustomPaint(painter: _LandscapePainter());
  }
}

class _LandscapePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Far ridge (lighter, purple haze).
    final far = Path()
      ..moveTo(0, h * 0.55)
      ..lineTo(w * 0.15, h * 0.35)
      ..lineTo(w * 0.28, h * 0.5)
      ..lineTo(w * 0.45, h * 0.22)
      ..lineTo(w * 0.62, h * 0.48)
      ..lineTo(w * 0.78, h * 0.3)
      ..lineTo(w, h * 0.52)
      ..lineTo(w, h * 0.62)
      ..lineTo(0, h * 0.62)
      ..close();
    canvas.drawPath(far, Paint()..color = const Color(0xFF2A2A6B).withValues(alpha: 0.75));

    // Near ridge (darker).
    final near = Path()
      ..moveTo(0, h * 0.66)
      ..lineTo(w * 0.2, h * 0.46)
      ..lineTo(w * 0.36, h * 0.6)
      ..lineTo(w * 0.55, h * 0.4)
      ..lineTo(w * 0.75, h * 0.62)
      ..lineTo(w * 0.9, h * 0.5)
      ..lineTo(w, h * 0.64)
      ..lineTo(w, h * 0.66)
      ..lineTo(0, h * 0.66)
      ..close();
    canvas.drawPath(near, Paint()..color = const Color(0xFF0B1233));

    // Lake with a faint vertical glow.
    final lake = Rect.fromLTRB(0, h * 0.66, w, h);
    canvas.drawRect(
      lake,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3A2C8F), Color(0xFF0A0F2C)],
        ).createShader(lake),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
