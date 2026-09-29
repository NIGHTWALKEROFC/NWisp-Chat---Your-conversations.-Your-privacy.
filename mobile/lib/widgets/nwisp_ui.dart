import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Small shared pieces of the NWisp look, used by the splash, onboarding,
/// login, settings, stories and chat list screens so they all match.

/// Gradient (accent -> violet) rounded button — the big "Next", "Login",
/// "Get Started" style button from the design.
class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final double height;

  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !loading;
    return Opacity(
      opacity: onPressed == null && !loading ? 0.5 : 1,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: AppTheme.brandGradient(scheme.primary),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onPressed : null,
            child: Center(
              child: loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded, thin-bordered surface — the "card" look used all over the
/// design (settings groups, privacy rows, list blocks).
class NwispCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  const NwispCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: child,
    );
  }
}

/// Gradient ring around an avatar (stories). [seen] = grey ring, [dashed]
/// isn't needed — a plain ring is enough. [ring] false = no ring at all.
class GradientRing extends StatelessWidget {
  final Widget child;
  final bool seen;
  final bool ring;
  final double padding;

  const GradientRing({
    super.key,
    required this.child,
    this.seen = false,
    this.ring = true,
    this.padding = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!ring) return child;
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: seen
            ? LinearGradient(colors: [scheme.outlineVariant, scheme.outlineVariant])
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF4C7DFF), Color(0xFF9B5CFF), Color(0xFF2FD3C4)],
              ),
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
        child: child,
      ),
    );
  }
}

/// The NWisp "N" mark — two bars joined by a diagonal, filled with the
/// brand gradient. Drawn in code so no image asset is needed.
class NwispLogo extends StatelessWidget {
  final double size;
  const NwispLogo({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF38C8FF), Color(0xFF4C7DFF), Color(0xFF9B5CFF)],
    ).createShader(rect);

    // Slightly slanted "N": left bar, diagonal, right bar.
    final left = Path()
      ..moveTo(w * 0.12, h * 0.95)
      ..lineTo(w * 0.12, h * 0.22)
      ..lineTo(w * 0.36, h * 0.05)
      ..lineTo(w * 0.36, h * 0.62)
      ..close();
    final diagonal = Path()
      ..moveTo(w * 0.36, h * 0.05)
      ..lineTo(w * 0.60, h * 0.05)
      ..lineTo(w * 0.60, h * 0.40)
      ..lineTo(w * 0.36, h * 0.62)
      ..close();
    final right = Path()
      ..moveTo(w * 0.64, h * 0.38)
      ..lineTo(w * 0.88, h * 0.20)
      ..lineTo(w * 0.88, h * 0.95)
      ..lineTo(w * 0.64, h * 0.95)
      ..close();

    final paint = Paint()
      ..shader = shader
      ..isAntiAlias = true;
    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
    canvas.drawPath(
      diagonal,
      Paint()
        ..shader = shader
        ..color = Colors.white.withValues(alpha: 0.85)
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// "NWisp Chat" — the first word in the brand gradient, the second plain.
class NwispWordmark extends StatelessWidget {
  final double fontSize;
  final MainAxisAlignment alignment;
  const NwispWordmark({super.key, this.fontSize = 28, this.alignment = MainAxisAlignment.center});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignment,
      children: [
        ShaderMask(
          shaderCallback: (r) => AppTheme.brandGradient(scheme.primary).createShader(r),
          child: Text(
            'NWisp',
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Colors.white),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Chat',
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: scheme.onSurface),
        ),
      ],
    );
  }
}

/// Navy backdrop with a soft blue/violet glow — behind splash, onboarding
/// and login. In light mode it falls back to a plain surface colour.
class NwispBackdrop extends StatelessWidget {
  final Widget child;
  const NwispBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    if (!dark) return ColoredBox(color: scheme.surface, child: child);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF060A1B), Color(0xFF0A1030), Color(0xFF130F3A)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            left: -80,
            child: _glow(const Color(0xFF3B5BFF), 320),
          ),
          Positioned(
            bottom: -140,
            right: -100,
            child: _glow(const Color(0xFF8A4DFF), 340),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }

  Widget _glow(Color c, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [c.withValues(alpha: 0.28), c.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

/// The blue verified tick shown next to the official "NWisp Chat" name —
/// same idea as the tick Telegram puts on its own service account.
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF38A8FF), Color(0xFF2F6BFF)],
        ),
      ),
      child: Icon(Icons.check_rounded, size: size * 0.72, color: Colors.white),
    );
  }
}

/// Round avatar for the official account: the NWisp "N" on a navy disc.
class NwispOfficialAvatar extends StatelessWidget {
  final double radius;
  const NwispOfficialAvatar({super.key, this.radius = 26});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF101A44),
      child: NwispLogo(size: radius * 1.15),
    );
  }
}
