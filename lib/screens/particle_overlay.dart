// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 粒子覆盖层——浮动粒子效果叠加层（心形/星形/火花/问号等形状）
// ═══════════════════════════════════════════════════════════════

library;


import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ui_controller.dart';

/// 粒子特效覆盖层——浮动心形/星形/火花/问号等装饰粒子
class ParticleOverlay extends StatefulWidget {
  const ParticleOverlay({super.key});

  @override
  State<ParticleOverlay> createState() => _ParticleOverlayState();
}

class _ParticleOverlayState extends State<ParticleOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  ParticleConfig? _config;
  final _particles = <_Particle>[];
  int _lastBurst = -1;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    UIController().addListener(_onBurst);
  }

  @override
  void dispose() {
    UIController().removeListener(_onBurst);
    _ctrl.dispose();
    super.dispose();
  }

  void _onBurst() {
    final ui = UIController();
    if (ui.particleBurst != _lastBurst && ui.particles != null) {
      _lastBurst = ui.particleBurst;
      _config = ui.particles;
      _spawnParticles(_config!);
      _ctrl.forward(from: 0);
      setState(() {});
    }
  }

  void _spawnParticles(ParticleConfig config) {
    final rng = math.Random();
    _particles.clear();
    for (int i = 0; i < config.count; i++) {
      _particles.add(_Particle(
        x: 0.5 + (rng.nextDouble() - 0.5) * config.spread,
        y: 0.5 + (rng.nextDouble() - 0.5) * config.spread * 0.5,
        vx: (rng.nextDouble() - 0.5) * 0.02 * config.spread,
        vy: config.path == 'rain' ? 0.03 : config.path == 'fly_up' ? -0.025 : (rng.nextDouble() - 0.5) * 0.02,
        size: 8 + rng.nextDouble() * 16,
        rotation: rng.nextDouble() * 360,
        rotSpeed: (rng.nextDouble() - 0.5) * 8,
        opacity: 0.7 + rng.nextDouble() * 0.3,
        shape: config.shape,
        color: config.color,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_config == null || _ctrl.value >= 1.0) return const SizedBox.shrink();

    return IgnorePointer(
      child: AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final progress = _ctrl.value;
        final fadeOut = progress > 0.8 ? (1.0 - (progress - 0.8) / 0.2) : 1.0;
        final size = MediaQuery.of(context).size;
        return CustomPaint(
          size: size,
          painter: _ParticlePainter(
            particles: _particles,
            progress: progress,
            fadeOut: fadeOut,
          ),
        );
      },
    ),
    );
  }
}

class _Particle {
  double x, y, vx, vy, size, rotation, rotSpeed, opacity;
  String shape;
  Color color;
  _Particle({
    required this.x, required this.y, required this.vx, required this.vy,
    required this.size, required this.rotation, required this.rotSpeed,
    required this.opacity, required this.shape, required this.color,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double progress, fadeOut;
  _ParticlePainter({required this.particles, required this.progress, required this.fadeOut});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final w = canvasSize.width, h = canvasSize.height;
    for (final p in particles) {
      final curX = p.x + p.vx * progress * 2;
      final curY = p.y + p.vy * progress * 2;
      final px = curX * w, py = curY * h;
      final paint = Paint()..color = p.color.withValues(alpha: p.opacity * fadeOut);
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(p.rotation + p.rotSpeed * progress * 0.1);
      final s = p.size * (1.0 - progress * 0.3);

      switch (p.shape) {
        case 'heart':
          _drawHeart(canvas, s, paint);
          break;
        case 'star':
          _drawStar(canvas, s, paint);
          break;
        case 'spark':
          _drawSpark(canvas, s, paint);
          break;
        case '?':
          _drawQuestion(canvas, s, paint, p.color.withValues(alpha: p.opacity * fadeOut));
          break;
        default:
          canvas.drawCircle(Offset.zero, s / 2, paint);
      }
      canvas.restore();
    }
  }

  void _drawHeart(Canvas c, double s, Paint p) {
    final path = Path();
    final r = s * 0.25;
    path.moveTo(0, r * 1.5);
    path.cubicTo(-r * 1.5, 0, -r * 1.5, -r * 1.2, 0, -r * 1.6);
    path.cubicTo(r * 1.5, -r * 1.2, r * 1.5, 0, 0, r * 1.5);
    c.drawPath(path, p);
  }

  void _drawStar(Canvas c, double s, Paint p) {
    final path = Path();
    final r = s * 0.4;
    for (int i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * 4 * math.pi / 5;
      final px = math.cos(angle) * r;
      final py = math.sin(angle) * r;
      if (i == 0) { path.moveTo(px, py); } else { path.lineTo(px, py); }
    }
    path.close();
    c.drawPath(path, p);
  }

  void _drawSpark(Canvas c, double s, Paint p) {
    final path = Path();
    final r = s * 0.5;
    for (int i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      path.moveTo(0, 0);
      path.lineTo(math.cos(angle) * r, math.sin(angle) * r);
    }
    p.strokeWidth = 2;
    p.style = PaintingStyle.stroke;
    c.drawPath(path, p);
    p.style = PaintingStyle.fill;
  }

  void _drawQuestion(Canvas c, double s, Paint p, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: '?', style: TextStyle(color: color, fontSize: s * 1.2, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) =>
      old.progress != progress || old.fadeOut != fadeOut;
}
