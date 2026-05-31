/// Dynamic background canvas — AI-controlled rendering primitives.
/// Architecture: AI pushes bg_effects[{op, ...}] → painter renders.
/// Each op is a self-contained rendering primitive. Parse errors → skip that op.
/// If ALL ops fail or empty → floor layer (gradient/color) shows through.
///
/// Ops:
///   particles — configurable emitter with arbitrary polygon shapes
///   grid — perspective grid (sci-fi / cyberpunk)
///   pulse_ring — expanding concentric ring (holographic)
///   scanlines — moving horizontal/vertical lines (cyberpunk)
library;

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'ui_controller.dart';

class DynamicBackground extends StatefulWidget {
  const DynamicBackground({super.key});
  @override
  State<DynamicBackground> createState() => _DynamicBackgroundState();
}

class _DynamicBackgroundState extends State<DynamicBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  // Cache: avoid re-parsing effects every frame (H14 fix)
  List<Map<String, dynamic>>? _lastEffects;
  List<_BgOp> _cachedOps = const [];

  List<_BgOp> _getOps(List<Map<String, dynamic>>? effects) {
    if (effects == null) return const [];
    // Use identity check — same list reference = same effects
    if (identical(effects, _lastEffects)) return _cachedOps;
    _lastEffects = effects;
    _cachedOps = _BgPainter.parseOps(effects);
    return _cachedOps;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 120))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mood = UIController().mood;
    final effects = mood.bgEffects;
    final density = mood.particleDensity ?? 0.0;

    if ((effects == null || effects.isEmpty) && density <= 0.005) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          // Read UIController INSIDE builder — picks up changes between builds
          final m = UIController().mood;
          final efx = m.bgEffects ?? effects;
          final den = (m.particleDensity ?? 0.0).clamp(0.0, 1.0);
          final spd = m.particleSpeed ?? 1.0;
          final acc = m.accent ?? const Color(0xFFFFFFFF);
          final ops = _getOps((efx != null && efx.isNotEmpty) ? efx : effects);
          return CustomPaint(
            painter: _BgPainter(
              time: _ctrl.value * 120 * spd,
              density: den,
              color: acc,
              ops: ops,
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════
// PARSED OPS — validated at parse, safe to render
// ═══════════════════════════════════════════════

abstract class _BgOp {}

class _ParticleOp extends _BgOp {
  final List<Offset> poly; // polygon vertices (normalized), or empty for circle
  final bool isCircle, isEllipse;
  final double ellipseW, ellipseH;
  final Color color;
  final int count;
  final double size, speed, opacity;
  final int seed;
  final String? shape; // 'heart','star','spark','?' — shape drawn per particle

  _ParticleOp({
    this.poly = const [],
    this.isCircle = true,
    this.isEllipse = false,
    this.ellipseW = 1.0,
    this.ellipseH = 1.0,
    required this.color,
    required this.count,
    this.size = 4.0,
    this.speed = 1.0,
    this.opacity = 0.7,
    this.seed = 42,
    this.shape,
  });

  static _ParticleOp? tryParse(Map<String, dynamic> m) {
    final colorHex = m['color'] as String?;
    if (colorHex == null && m['color_hint'] == null) return null;
    final count = (m['count'] as num?)?.toInt() ?? 60;
    final size = (m['size'] as num?)?.toDouble() ?? 4.0;
    final speed = (m['speed'] as num?)?.toDouble() ?? 1.0;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.7;
    final shape = m['shape'] as String?;
    final seed = (m['seed'] as num?)?.toInt() ?? 42;

    Color color;
    if (colorHex != null) {
      final h = colorHex.replaceFirst('#', '');
      color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    } else {
      color = const Color(0xFFFFFFFF);
    }

    // Parse polygon vertices: "poly:x1,y1 x2,y2 ..."
    final polyStr = m['poly'] as String?;
    List<Offset> poly = [];
    bool isCircle = m['isCircle'] != false;
    bool isEllipse = m['isEllipse'] == true;
    double ew = 1.0, eh = 1.0;
    if (polyStr != null && polyStr.isNotEmpty) {
      isCircle = false;
      final pts = polyStr.split(RegExp(r'\s+'));
      for (final pt in pts) {
        final xy = pt.split(',');
        if (xy.length == 2) {
          final x = double.tryParse(xy[0]);
          final y = double.tryParse(xy[1]);
          if (x != null && y != null) poly.add(Offset(x, y));
        }
      }
      if (poly.isEmpty) isCircle = true;
    }
    if (isEllipse) {
      ew = (m['ellipse_w'] as num?)?.toDouble() ?? 1.0;
      eh = (m['ellipse_h'] as num?)?.toDouble() ?? 1.0;
    }

    return _ParticleOp(
      poly: poly,
      isCircle: isCircle,
      isEllipse: isEllipse,
      ellipseW: ew,
      ellipseH: eh,
      color: color,
      count: count.clamp(1, 300),
      size: size.clamp(1, 40),
      speed: speed.clamp(0.1, 5),
      opacity: opacity.clamp(0.1, 1.0),
      seed: seed,
      shape: shape,
    );
  }
}

class _GridOp extends _BgOp {
  final Color color;
  final int lines;
  final double opacity;
  _GridOp({required this.color, this.lines = 12, this.opacity = 0.15});

  static _GridOp? tryParse(Map<String, dynamic> m) {
    final colorHex = m['color'] as String? ?? '#FFFFFF';
    final h = colorHex.replaceFirst('#', '');
    final color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    final lines = (m['lines'] as num?)?.toInt() ?? 12;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.15;
    return _GridOp(color: color, lines: lines.clamp(4, 40), opacity: opacity.clamp(0.02, 0.5));
  }
}

class _RingOp extends _BgOp {
  final Color color;
  final int count;
  final double thickness, opacity;
  _RingOp({required this.color, this.count = 3, this.thickness = 1.5, this.opacity = 0.5});

  static _RingOp? tryParse(Map<String, dynamic> m) {
    final colorHex = m['color'] as String? ?? '#FFFFFF';
    final h = colorHex.replaceFirst('#', '');
    final color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    final count = (m['count'] as num?)?.toInt() ?? 3;
    final thickness = (m['thickness'] as num?)?.toDouble() ?? 1.5;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.5;
    return _RingOp(color: color, count: count.clamp(1, 10), thickness: thickness.clamp(0.5, 6), opacity: opacity.clamp(0.1, 1.0));
  }
}

class _ScanlineOp extends _BgOp {
  final Color color;
  final double spacing, opacity;
  final bool horizontal;
  _ScanlineOp({required this.color, this.spacing = 4.0, this.opacity = 0.06, this.horizontal = true});

  static _ScanlineOp? tryParse(Map<String, dynamic> m) {
    final colorHex = m['color'] as String? ?? '#FFFFFF';
    final h = colorHex.replaceFirst('#', '');
    final color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    final spacing = (m['spacing'] as num?)?.toDouble() ?? 4.0;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.06;
    final horizontal = m['horizontal'] != false;
    return _ScanlineOp(color: color, spacing: spacing.clamp(1, 20), opacity: opacity.clamp(0.01, 0.3), horizontal: horizontal);
  }
}

class _CanvasOp extends _BgOp {
  final String shape; // 'ellipse','rect','circle','path'
  final Color color;
  final double blur, opacity, x, y, w, h, rotation;
  final String blend;
  _CanvasOp({
    this.shape = 'ellipse', required this.color, this.blur = 0, this.opacity = 0.5,
    this.x = 0.5, this.y = 0.5, this.w = 0.6, this.h = 0.4, this.rotation = 0,
    this.blend = 'screen',
  });

  static _CanvasOp? tryParse(Map<String, dynamic> m) {
    final shape = m['shape'] as String? ?? 'ellipse';
    final colorHex = m['color'] as String? ?? '#FFFFFF';
    final h = colorHex.replaceFirst('#', '');
    final color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    final blur = (m['blur'] as num?)?.toDouble() ?? 0;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.5;
    final x = (m['x'] as num?)?.toDouble() ?? 0.5;
    final y = (m['y'] as num?)?.toDouble() ?? 0.5;
    final w = (m['w'] as num?)?.toDouble() ?? 0.6;
    final hh = (m['h'] as num?)?.toDouble() ?? 0.4;
    final rotation = (m['rotation'] as num?)?.toDouble() ?? 0;
    final blend = m['blend'] as String? ?? 'screen';
    return _CanvasOp(shape: shape, color: color, blur: blur.clamp(0, 80),
      opacity: opacity.clamp(0.05, 1.0), x: x.clamp(-0.5, 1.5), y: y.clamp(-0.5, 1.5),
      w: w.clamp(0.01, 3), h: hh.clamp(0.01, 3), rotation: rotation, blend: blend);
  }
}

// ═══════════════════════════════════════════════
// PAINTER
// ═══════════════════════════════════════════════

class _BgPainter extends CustomPainter {
  final double time, density;
  final Color color;
  final List<_BgOp> ops;

  _BgPainter({required this.time, required this.density, required this.color, required this.ops});

  static List<_BgOp> parseOps(List<Map<String, dynamic>>? effects) {
    if (effects == null || effects.isEmpty) return const [];
    final result = <_BgOp>[];
    for (final m in effects) {
      final op = _parseTopOp(m);
      if (op != null) result.add(op);
    }
    return result;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (ops.isEmpty && density <= 0.005) return;

    // Floor
    final paint = Paint();
    final baseAlpha = (density * 0.15).clamp(0.0, 0.15);
    if (baseAlpha > 0.001) {
      paint.color = color.withValues(alpha: baseAlpha);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    }

    for (final op in ops) {
      if (op is _ParticleOp) _drawParticles(canvas, size, op);
      if (op is _GridOp) _drawGrid(canvas, size, op);
      if (op is _RingOp) _drawRings(canvas, size, op);
      if (op is _ScanlineOp) _drawScanlines(canvas, size, op);
      if (op is _CanvasOp) _drawCanvasOp(canvas, size, op);
    }

    _renderCustom(canvas, size);
  }

  void _renderCustom(Canvas canvas, Size size) {
    // Hook for compile-time custom rendering via write_file injection.
    // Override _BgPainter._renderCustom in a separate file build pipeline.
  }

  static _BgOp? _parseTopOp(Map<String, dynamic> m) {
    final op = m['op'] as String?;
    if (op == null) return null;
    switch (op) {
      case 'particles': return _ParticleOp.tryParse(m);
      case 'grid': return _GridOp.tryParse(m);
      case 'pulse_ring': return _RingOp.tryParse(m);
      case 'scanlines': return _ScanlineOp.tryParse(m);
      case 'canvas': return _CanvasOp.tryParse(m);
      default: return null;
    }
  }

  // Deterministic hash — same seeds produce same values across frames
  static double _hash(int i, int a, int b) {
    int h = i * 0x9E3779B9 + a * 0x85EBCA77 + b * 0xC2B2AE35;
    h = ((h >> 16) ^ h) * 0x45D9F3B;
    h = ((h >> 16) ^ h) * 0x45D9F3B;
    return (h & 0x7FFFFFFF) / 0x7FFFFFFF;
  }

  void _drawParticles(Canvas canvas, Size size, _ParticleOp e) {
    final paint = Paint()..color = e.color.withValues(alpha: e.opacity);
    final w = size.width, h = size.height;
    for (int i = 0; i < e.count; i++) {
      final px = _hash(i, e.seed, 42);
      final py = _hash(i, e.seed, 5678);
      final offsetX = (px - 0.5) * 0.2 * e.speed * (time % 10);
      final offsetY = (py - 0.5) * 0.2 * e.speed * (time % 13);
      final x = ((px + offsetX) % 1.0 + 1.0) % 1.0;
      final y = ((py + offsetY) % 1.0 + 1.0) % 1.0;
      final s = e.size * (0.5 + _hash(i, e.seed, 999) * 0.5);
      final cx = x * w, cy = y * h;

      if (e.shape == 'heart') { _drawHeart(canvas, cx, cy, s, paint); continue; }
      if (e.shape == 'star') { _drawStar(canvas, cx, cy, s, paint); continue; }
      if (e.shape == 'spark') { _drawSpark(canvas, cx, cy, s, paint); continue; }
      if (e.shape == '?') { _drawQuestion(canvas, cx, cy, s, paint, e.color); continue; }

      if (e.isCircle) {
        canvas.drawCircle(Offset(cx, cy), s / 2, paint);
      } else if (e.isEllipse) {
        canvas.save();
        canvas.translate(cx, cy);
        canvas.scale(e.ellipseW, e.ellipseH);
        canvas.drawCircle(Offset.zero, s / 2, paint);
        canvas.restore();
      } else if (e.poly.isNotEmpty) {
        final path = Path();
        final scale = s / 20; // normalize
        path.moveTo(e.poly.first.dx * scale, e.poly.first.dy * scale);
        for (int j = 1; j < e.poly.length; j++) {
          path.lineTo(e.poly[j].dx * scale, e.poly[j].dy * scale);
        }
        path.close();
        canvas.save();
        canvas.translate(cx, cy);
        canvas.drawPath(path, paint);
        canvas.restore();
      } else {
        canvas.drawCircle(Offset(cx, cy), s / 2, paint);
      }
    }
  }

  void _drawHeart(Canvas c, double x, double y, double s, Paint p) {
    final path = Path();
    final r = s * 0.25;
    path.moveTo(x, y + r * 1.5);
    path.cubicTo(x - r * 1.5, y, x - r * 1.5, y - r * 1.2, x, y - r * 1.6);
    path.cubicTo(x + r * 1.5, y - r * 1.2, x + r * 1.5, y, x, y + r * 1.5);
    c.drawPath(path, p);
  }

  void _drawStar(Canvas c, double x, double y, double s, Paint p) {
    final path = Path();
    final r = s * 0.4;
    for (int i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * 4 * math.pi / 5;
      final px = x + math.cos(angle) * r;
      final py = y + math.sin(angle) * r;
      if (i == 0) { path.moveTo(px, py); } else { path.lineTo(px, py); }
    }
    path.close();
    c.drawPath(path, p);
  }

  void _drawSpark(Canvas c, double x, double y, double s, Paint p) {
    final path = Path();
    final r = s * 0.5;
    for (int i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      path.moveTo(x, y);
      path.lineTo(x + math.cos(angle) * r, y + math.sin(angle) * r);
    }
    p.strokeWidth = 2;
    p.style = PaintingStyle.stroke;
    c.drawPath(path, p);
    p.style = PaintingStyle.fill;
  }

  void _drawQuestion(Canvas c, double x, double y, double s, Paint p, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: '?', style: TextStyle(color: color, fontSize: s * 1.2, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(x - tp.width / 2, y - tp.height / 2));
  }

  void _drawGrid(Canvas canvas, Size size, _GridOp g) {
    final paint = Paint()
      ..color = g.color.withValues(alpha: g.opacity)
      ..strokeWidth = 0.5;
    final w = size.width, h = size.height;
    final cx = w / 2, cy = h * 0.4;

    for (int i = -g.lines; i <= g.lines; i++) {
      final x = cx + i * (w / g.lines);
      final t = math.sin(time * 0.3 + i * 0.5) * 0.1;
      canvas.drawLine(Offset(x, 0), Offset(cx + (x - cx) * 0.1, cy * (1 + t)), paint);
      final y = cy + i * (h / g.lines);
      canvas.drawLine(Offset(0, y), Offset(w, y + (y - cy) * 0.05 * math.sin(time * 0.2)), paint);
    }
  }

  void _drawRings(Canvas canvas, Size size, _RingOp r) {
    final paint = Paint()
      ..color = r.color.withValues(alpha: r.opacity)
      ..strokeWidth = r.thickness
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2, cy = size.height / 2;
    final maxR = math.sqrt(cx * cx + cy * cy);

    for (int i = 0; i < r.count; i++) {
      final delay = i * 0.3;
      final phase = (time * 0.5 + delay) % 1.0;
      final radius = phase * maxR;
      final fade = _fadeOpacity(phase);
      paint.color = r.color.withValues(alpha: r.opacity * fade);
      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }
  }

  void _drawScanlines(Canvas canvas, Size size, _ScanlineOp s) {
    final paint = Paint()..color = s.color.withValues(alpha: s.opacity);
    final w = size.width, h = size.height;
    final offset = (time * 40) % s.spacing;

    if (s.horizontal) {
      for (double y = offset; y < h; y += s.spacing) {
        canvas.drawRect(Rect.fromLTWH(0, y, w, 1), paint);
      }
    } else {
      for (double x = offset; x < w; x += s.spacing) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 1, h), paint);
      }
    }
  }

  void _drawCanvasOp(Canvas canvas, Size size, _CanvasOp op) {
    final paint = Paint()..color = op.color.withValues(alpha: op.opacity);
    if (op.blur > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, op.blur);
    }
    // Apply blend mode
    switch (op.blend) {
      case 'screen': paint.blendMode = BlendMode.screen; break;
      case 'overlay': paint.blendMode = BlendMode.overlay; break;
      case 'softLight': paint.blendMode = BlendMode.softLight; break;
      case 'plus': paint.blendMode = BlendMode.plus; break;
      default: break;
    }

    canvas.save();
    final cx = op.x * size.width, cy = op.y * size.height;
    canvas.translate(cx, cy);
    if (op.rotation != 0) canvas.rotate(op.rotation * math.pi / 180);
    final rw = op.w * size.width, rh = op.h * size.height;

    switch (op.shape) {
      case 'rect':
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: rw, height: rh), paint);
        break;
      case 'circle':
        canvas.drawCircle(Offset.zero, (rw + rh) / 4, paint);
        break;
      case 'path':
        // Simple diamond as default path shape
        final path = Path()
          ..moveTo(0, -rh / 2)
          ..lineTo(rw / 2, 0)
          ..lineTo(0, rh / 2)
          ..lineTo(-rw / 2, 0)
          ..close();
        canvas.drawPath(path, paint);
        break;
      case 'ellipse':
      default:
        canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: rw, height: rh), paint);
    }
    canvas.restore();
  }

  double _fadeOpacity(double frac) {
    if (frac < 0.1) return frac / 0.1;
    if (frac > 0.8) return 1.0 - (frac - 0.8) / 0.2;
    return 1.0;
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) =>
      old.time != time || old.density != density || old.color != color || old.ops != ops;
}
