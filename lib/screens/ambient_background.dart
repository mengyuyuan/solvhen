// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 环境背景——纯色/渐变静态背景，无动画开销
// ═══════════════════════════════════════════════════════════════

library;

/// Lightweight, no UIController dependency. Used across settings pages.

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/theme_provider.dart';

/// 环境背景——纯色/渐变静态背景，零动画开销
class AmbientBackground extends StatefulWidget {
  final ThemeColors colors;
  const AmbientBackground({super.key, required this.colors});
  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _rng = math.Random(42);
  late final List<_Orb> _orbs;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 30))..repeat();
    _orbs = List.generate(12, (_) => _Orb(
      x: _rng.nextDouble(),
      y: _rng.nextDouble(),
      radius: 60 + _rng.nextDouble() * 140,
      speed: 0.3 + _rng.nextDouble() * 0.5,
      opacity: 0.03 + _rng.nextDouble() * 0.06,
      hue: _rng.nextDouble() * 0.1,
    ));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value * math.pi * 2;
        return CustomPaint(
          painter: _OrbPainter(
            orbs: _orbs,
            time: t,
            accent: c.accent,
            isDark: c.isDark,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Orb {
  final double x, y, radius, speed, opacity, hue;
  _Orb({required this.x, required this.y, required this.radius, required this.speed, required this.opacity, required this.hue});
}

class _OrbPainter extends CustomPainter {
  final List<_Orb> orbs;
  final double time;
  final Color accent;
  final bool isDark;

  _OrbPainter({required this.orbs, required this.time, required this.accent, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    for (final orb in orbs) {
      final ox = (orb.x + math.sin(time * orb.speed) * 0.06) % 1.0;
      final oy = (orb.y + math.cos(time * orb.speed * 0.7) * 0.04) % 1.0;

      // Soft color — slightly tinted with accent
      final base = isDark ? const Color(0xFF6E6E8A) : const Color(0xFFD0D0E0);
      final tinted = Color.lerp(base, accent, orb.hue)!;
      final color = tinted.withValues(alpha: orb.opacity);

      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(ox * w, oy * h),
          orb.radius,
          [color, color.withValues(alpha: 0)],
        )
        ..blendMode = BlendMode.srcOver;

      canvas.drawCircle(Offset(ox * w, oy * h), orb.radius * 1.8, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.time != time;
}
