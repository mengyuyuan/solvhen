import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_provider.dart';

/// Static, low-cost dot field used across Solvhen surfaces. It deliberately
/// avoids an animation controller so the visual identity has no background
/// battery cost.
class SolvhenDotField extends StatelessWidget {
  const SolvhenDotField({
    super.key,
    required this.color,
    this.density = 1,
  });

  final Color color;
  final double density;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _SolvhenDotPainter(color: color, density: density),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class SolvhenBackdrop extends StatelessWidget {
  const SolvhenBackdrop({
    super.key,
    required this.colors,
    required this.child,
    this.density = 1,
  });

  final ThemeColors colors;
  final Widget child;
  final double density;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: colors.bgGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SolvhenDotField(color: colors.dotColor, density: density),
          child,
        ],
      ),
    );
  }
}

class SolvhenPanel extends StatelessWidget {
  const SolvhenPanel({
    super.key,
    required this.colors,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.borderColor,
    this.backgroundColor,
    this.showShadow = true,
  });

  final ThemeColors colors;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? borderColor;
  final Color? backgroundColor;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? colors.glassBg,
        borderRadius: BorderRadius.circular(radius),
        border:
            Border.all(color: borderColor ?? colors.glassBorder, width: 0.8),
        boxShadow: showShadow ? colors.shadowCard : null,
      ),
      child: child,
    );
  }
}

class SolvhenSectionLabel extends StatelessWidget {
  const SolvhenSectionLabel({
    super.key,
    required this.colors,
    required this.label,
    this.trailing,
  });

  final ThemeColors colors;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: colors.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.35,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class SolvhenTag extends StatelessWidget {
  const SolvhenTag({
    super.key,
    required this.colors,
    required this.label,
    this.icon,
    this.color,
  });

  final ThemeColors colors;
  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? colors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: colors.isDark ? 0.18 : 0.09),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: resolved.withValues(alpha: 0.26), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: resolved),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
                color: resolved, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Brand-neutral dot-matrix object used for empty and onboarding states.
/// It intentionally is not the eye/avatar: the animated eye is reserved for
/// real agent state in the top bar and at the end of an assistant response.
class SolvhenMatrixMark extends StatelessWidget {
  const SolvhenMatrixMark({
    super.key,
    required this.colors,
    this.width = 184,
    this.height = 112,
  });

  final ThemeColors colors;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SolvhenMatrixPainter(
          primary: colors.accent,
          secondary: colors.navy,
          frame: colors.separator,
        ),
      ),
    );
  }
}

/// Compact outlined icon surface shared by app bars and utility controls.
class SolvhenIconSurface extends StatelessWidget {
  const SolvhenIconSurface({
    super.key,
    required this.colors,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 38,
  });

  final ThemeColors colors;
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: colors.accentFaint,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: 20, color: colors.textSecondary),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _SolvhenDotPainter extends CustomPainter {
  const _SolvhenDotPainter({required this.color, required this.density});

  final Color color;
  final double density;

  @override
  void paint(Canvas canvas, Size size) {
    final spacing = 22 / density.clamp(0.55, 1.8);
    final paint = Paint()..style = PaintingStyle.fill;
    final columns = (size.width / spacing).ceil();
    final rows = (size.height / spacing).ceil();

    for (var row = 0; row <= rows; row++) {
      for (var column = 0; column <= columns; column++) {
        final x = column * spacing + (row.isOdd ? spacing / 2 : 0);
        final y = row * spacing;
        final topRight = _falloff(
            x, y, size.width * 0.86, size.height * 0.10, size.width * 0.50);
        final bottomLeft = _falloff(
            x, y, size.width * 0.10, size.height * 0.90, size.width * 0.56);
        final band = 0.25 + 0.25 * math.sin((x + y) / 58);
        final weight = math.max(topRight, bottomLeft) * band;
        if (weight < 0.055) continue;
        paint.color =
            color.withValues(alpha: (0.08 + weight * 0.55).clamp(0.0, 0.30));
        canvas.drawCircle(Offset(x, y), 0.65 + weight * 0.65, paint);
      }
    }

    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..strokeWidth = 0.8;
    _crosshair(
        canvas, Offset(size.width * 0.88, size.height * 0.18), linePaint);
    _crosshair(
        canvas, Offset(size.width * 0.12, size.height * 0.76), linePaint);
  }

  double _falloff(double x, double y, double cx, double cy, double radius) {
    final dx = x - cx;
    final dy = y - cy;
    final distance = math.sqrt(dx * dx + dy * dy);
    return (1 - distance / radius).clamp(0.0, 1.0);
  }

  void _crosshair(Canvas canvas, Offset center, Paint paint) {
    canvas.drawLine(center.translate(-8, 0), center.translate(8, 0), paint);
    canvas.drawLine(center.translate(0, -8), center.translate(0, 8), paint);
    canvas.drawCircle(center, 2.2, paint..style = PaintingStyle.stroke);
    paint.style = PaintingStyle.fill;
  }

  @override
  bool shouldRepaint(covariant _SolvhenDotPainter oldDelegate) {
    return color != oldDelegate.color || density != oldDelegate.density;
  }
}

class _SolvhenMatrixPainter extends CustomPainter {
  const _SolvhenMatrixPainter({
    required this.primary,
    required this.secondary,
    required this.frame,
  });

  final Color primary;
  final Color secondary;
  final Color frame;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 2);
    final dot = Paint()..style = PaintingStyle.fill;
    final line = Paint()
      ..color = frame.withValues(alpha: 0.75)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    // Three staggered isometric data planes. Each point is deterministic and
    // static, keeping the empty state crisp and battery-free.
    const columns = 15;
    const rows = 9;
    final stepX = size.width / 24;
    final stepY = size.height / 23;
    for (var layer = 0; layer < 3; layer++) {
      final layerShift =
          Offset((layer - 1) * stepX * 1.8, -layer * stepY * 1.4);
      for (var row = 0; row < rows; row++) {
        for (var column = 0; column < columns; column++) {
          final x = (column - (columns - 1) / 2) * stepX;
          final y = (row - (rows - 1) / 2) * stepY;
          final px = center.dx + x + y * 0.42 + layerShift.dx;
          final py = center.dy + y - x * 0.18 + layerShift.dy;
          final edge = (column == 0 ||
                  column == columns - 1 ||
                  row == 0 ||
                  row == rows - 1)
              ? 1.0
              : 0.65;
          final wave = 0.55 + 0.45 * math.sin((column + row * 1.7) * 0.72);
          dot.color = (layer == 1 ? primary : secondary).withValues(
            alpha: (0.16 + edge * wave * (layer == 1 ? 0.50 : 0.25))
                .clamp(0.12, 0.72),
          );
          canvas.drawCircle(Offset(px, py), layer == 1 ? 1.25 : 0.9, dot);
        }
      }
    }

    final rect = Rect.fromLTWH(8, 7, size.width - 16, size.height - 14);
    const corner = 13.0;
    final path = Path()
      ..moveTo(rect.left, rect.top + corner)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + corner, rect.top)
      ..moveTo(rect.right - corner, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + corner)
      ..moveTo(rect.right, rect.bottom - corner)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - corner, rect.bottom)
      ..moveTo(rect.left + corner, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - corner);
    canvas.drawPath(path, line);

    line.color = primary.withValues(alpha: 0.28);
    canvas.drawLine(
      Offset(center.dx - 15, center.dy),
      Offset(center.dx + 15, center.dy),
      line,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 15),
      Offset(center.dx, center.dy + 15),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _SolvhenMatrixPainter oldDelegate) =>
      primary != oldDelegate.primary ||
      secondary != oldDelegate.secondary ||
      frame != oldDelegate.frame;
}
