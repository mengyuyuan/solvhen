/// Solvhen AI手机智能体 — 动态背景画布
/// AI 通过 bg_effects[{op, ...}] 控制渲染原语，painter 逐帧绘制。
/// 每个 op 是自包含的渲染原语。解析错误 → 跳过该 op。
/// 若所有 op 失败或为空 → 底层渐变色作为背景显示。
///
/// 支持的 Ops:
///   particles  — 可配置粒子发射器（支持多边形/心形/星形等形状）
///   grid       — 透视网格（科幻/赛博朋克）
///   pulse_ring — 扩散同心圆环（全息效果）
///   scanlines  — 移动的水平/垂直线条（赛博朋克）
///   canvas     — 静态画布元素（椭圆/矩形/路径 + 模糊 + 混合模式）
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ui_controller.dart';

/// 动态背景绘制器
/// 负责：粒子系统 + 渐变背景 + 暗角效果 + 扫描线 + 网格
/// ⚠️ build()内禁止修改AnimationController状态——用addPostFrameCallback
class DynamicBackground extends StatefulWidget {
  const DynamicBackground({super.key});
  @override
  State<DynamicBackground> createState() => _DynamicBackgroundState();
}

class _DynamicBackgroundState extends State<DynamicBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  /// 缓存：避免每帧重复解析 effects 列表（H14 优化）
  List<Map<String, dynamic>>? _lastEffects;
  List<_BgOp> _cachedOps = const [];

  /// 获取解析后的 ops，相同 effects 引用直接返回缓存结果
  List<_BgOp> _getOps(List<Map<String, dynamic>>? effects) {
    if (effects == null) return const [];
    // 引用相等检查：相同列表引用 → 相同 effects
    if (identical(effects, _lastEffects)) return _cachedOps;
    _lastEffects = effects;
    _cachedOps = _BgPainter.parseOps(effects);
    return _cachedOps;
  }

  @override
  void initState() {
    super.initState();
    // 120 秒长周期动画，避免快速循环
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 120));
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

    // 始终渲染：无显式 effects 时使用默认环境粒子
    final activeEffects = (effects != null && effects.isNotEmpty)
        ? effects
        : _defaultParticles(mood.accent ?? const Color(0xFFFFFFFF));

    // ⚠️ 启动动画循环：使用 addPostFrameCallback 避免 build() 中直接修改 AnimationController 状态
    if (!_ctrl.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ctrl.repeat();
      });
    }

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          // ⚠️ 在 builder 内部读取 UIController —— 捕捉 build 之间的变化
          final m = UIController().mood;
          final efx = m.bgEffects ?? activeEffects;
          final den = (m.particleDensity ?? 0.0).clamp(0.0, 1.0);
          final spd = m.particleSpeed ?? 1.0;
          final acc = m.accent ?? const Color(0xFFFFFFFF);
          final ops = _getOps(efx.isNotEmpty ? efx : activeEffects);
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

  /// 默认环境粒子：无 AI 设置 effects 时的保底渲染
  List<Map<String, dynamic>> _defaultParticles(Color accent) {
    // ⚠️ 颜色编码：value 是 ARGB int → hex → 去掉 Alpha 通道 → RRGGBB
    final hex = '#${accent.value.toRadixString(16).padLeft(8, '0').substring(2)}';
    return [
      {
        'op': 'particles',
        'count': 25,
        'speed': 0.4,
        'size': 0.6,
        'opacity': 0.25,
        'color': hex,
        'shape': 'circle',
        'drift': 0.3,
      },
    ];
  }
}

// ═══════════════════════════════════════════════
// 解析后的 Ops —— 解析时校验，渲染时安全使用
// ═══════════════════════════════════════════════

/// 背景操作基类
abstract class _BgOp {}

/// 粒子操作：支持圆形/椭圆/多边形/特殊形状（心形/星形等）
class _ParticleOp extends _BgOp {
  final List<Offset> poly;   // 多边形顶点（归一化坐标），空表示圆形
  final bool isCircle, isEllipse;
  final double ellipseW, ellipseH;
  final Color color;
  final int count;
  final double size, speed, opacity;
  final int seed;
  final String? shape;       // 'heart','star','spark','?' — 每粒子的特殊形状

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

  /// 从 JSON map 安全解析粒子配置，失败返回 null
  static _ParticleOp? tryParse(Map<String, dynamic> m) {
    final colorHex = m['color'] as String?;
    if (colorHex == null && m['color_hint'] == null) return null;
    final count = (m['count'] as num?)?.toInt() ?? 60;
    final size = (m['size'] as num?)?.toDouble() ?? 4.0;
    final speed = (m['speed'] as num?)?.toDouble() ?? 1.0;
    final opacity = (m['opacity'] as num?)?.toDouble() ?? 0.7;
    final shape = m['shape'] as String?;
    final seed = (m['seed'] as num?)?.toInt() ?? 42;

    // ⚠️ 颜色解析：hex → int ARGB。6位补FF，8位直接用。
    // 此逻辑与 ui_controller.dart 中的 _parseColor 重复，应提取到共享工具函数。
    Color color;
    if (colorHex != null) {
      final h = colorHex.replaceFirst('#', '');
      color = Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
    } else {
      color = const Color(0xFFFFFFFF);
    }

    // 解析多边形顶点："poly:x1,y1 x2,y2 ..." 格式
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

/// 透视网格操作：科幻/赛博朋克风格的线条网格
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

/// 扩散圆环操作：全息风格的同心圆
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

/// 扫描线操作：移动的水平/垂直线条
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

/// 画布元素操作：静态形状（椭圆/矩形/圆形/路径）+ 模糊 + 混合模式
class _CanvasOp extends _BgOp {
  final String shape;   // 'ellipse','rect','circle','path'
  final Color color;
  final double blur, opacity, x, y, w, h, rotation;
  final String blend;   // 'screen','overlay','softLight','plus'
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
// 自定义 Painter：核心渲染引擎
// ═══════════════════════════════════════════════

class _BgPainter extends CustomPainter {
  final double time, density;
  final Color color;
  final List<_BgOp> ops;

  _BgPainter({required this.time, required this.density, required this.color, required this.ops});

  /// 解析 effects JSON → 类型安全的 op 列表。解析错误单独跳过。
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

    // 底层：密度驱动的半透明底色
    final paint = Paint();
    final baseAlpha = (density * 0.15).clamp(0.0, 0.15);
    if (baseAlpha > 0.001) {
      paint.color = color.withValues(alpha: baseAlpha);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    }

    // 按顺序渲染每个 op
    for (final op in ops) {
      if (op is _ParticleOp) _drawParticles(canvas, size, op);
      if (op is _GridOp) _drawGrid(canvas, size, op);
      if (op is _RingOp) _drawRings(canvas, size, op);
      if (op is _ScanlineOp) _drawScanlines(canvas, size, op);
      if (op is _CanvasOp) _drawCanvasOp(canvas, size, op);
    }

    _renderCustom(canvas, size);
  }

  /// 编译时自定义渲染钩子：可通过 write_file 注入额外渲染逻辑
  void _renderCustom(Canvas canvas, Size size) {
    // 默认空实现。在构建流水线中通过代码注入覆盖此方法。
  }

  /// 顶层 op 分发：根据 'op' 字段路由到对应的 tryParse
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

  /// 确定性哈希函数：相同 seed 产生相同的伪随机值，保证帧间一致
  static double _hash(int i, int a, int b) {
    int h = i * 0x9E3779B9 + a * 0x85EBCA77 + b * 0xC2B2AE35;
    h = ((h >> 16) ^ h) * 0x45D9F3B;
    h = ((h >> 16) ^ h) * 0x45D9F3B;
    return (h & 0x7FFFFFFF) / 0x7FFFFFFF;
  }

  /// 绘制粒子系统：位置由哈希决定，运动由 time 驱动
  void _drawParticles(Canvas canvas, Size size, _ParticleOp e) {
    final paint = Paint()..color = e.color.withValues(alpha: e.opacity);
    final w = size.width, h = size.height;
    for (int i = 0; i < e.count; i++) {
      // 确定性位置 + time 驱动的偏移
      final px = _hash(i, e.seed, 42);
      final py = _hash(i, e.seed, 5678);
      final offsetX = (px - 0.5) * 0.2 * e.speed * (time % 10);
      final offsetY = (py - 0.5) * 0.2 * e.speed * (time % 13);
      final x = ((px + offsetX) % 1.0 + 1.0) % 1.0;
      final y = ((py + offsetY) % 1.0 + 1.0) % 1.0;
      final s = e.size * (0.5 + _hash(i, e.seed, 999) * 0.5);
      final cx = x * w, cy = y * h;

      // ⚠️ 特殊形状绘制：与 particle_overlay.dart 中的逻辑重复，应提取到共享模块
      if (e.shape == 'heart') { _drawHeart(canvas, cx, cy, s, paint); continue; }
      if (e.shape == 'star') { _drawStar(canvas, cx, cy, s, paint); continue; }
      if (e.shape == 'spark') { _drawSpark(canvas, cx, cy, s, paint); continue; }
      if (e.shape == '?') { _drawQuestion(canvas, cx, cy, s, paint, e.color); continue; }

      // 默认形状：圆形 / 椭圆 / 多边形
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
        final scale = s / 20; // 归一化缩放
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

  /// 绘制心形：三次贝塞尔曲线
  void _drawHeart(Canvas c, double x, double y, double s, Paint p) {
    final path = Path();
    final r = s * 0.25;
    path.moveTo(x, y + r * 1.5);
    path.cubicTo(x - r * 1.5, y, x - r * 1.5, y - r * 1.2, x, y - r * 1.6);
    path.cubicTo(x + r * 1.5, y - r * 1.2, x + r * 1.5, y, x, y + r * 1.5);
    c.drawPath(path, p);
  }

  /// 绘制五角星
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

  /// 绘制十字星芒
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

  /// 绘制问号文本
  void _drawQuestion(Canvas c, double x, double y, double s, Paint p, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: '?', style: TextStyle(color: color, fontSize: s * 1.2, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(x - tp.width / 2, y - tp.height / 2));
  }

  /// 绘制透视网格：向中心点汇聚的水平/垂直线
  void _drawGrid(Canvas canvas, Size size, _GridOp g) {
    final paint = Paint()
      ..color = g.color.withValues(alpha: g.opacity)
      ..strokeWidth = 0.5;
    final w = size.width, h = size.height;
    final cx = w / 2, cy = h * 0.4;  // 汇聚点偏上

    for (int i = -g.lines; i <= g.lines; i++) {
      final x = cx + i * (w / g.lines);
      final t = math.sin(time * 0.3 + i * 0.5) * 0.1;
      canvas.drawLine(Offset(x, 0), Offset(cx + (x - cx) * 0.1, cy * (1 + t)), paint);
      final y = cy + i * (h / g.lines);
      canvas.drawLine(Offset(0, y), Offset(w, y + (y - cy) * 0.05 * math.sin(time * 0.2)), paint);
    }
  }

  /// 绘制扩散圆环：从中心向外扩散，带淡入淡出
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

  /// 绘制扫描线：水平或垂直移动
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

  /// 绘制画布元素：支持模糊、旋转和混合模式
  void _drawCanvasOp(Canvas canvas, Size size, _CanvasOp op) {
    final paint = Paint()..color = op.color.withValues(alpha: op.opacity);
    if (op.blur > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, op.blur);
    }
    // 混合模式
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
        // 默认菱形路径
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

  /// 淡入淡出函数：0→0.1 淡入，0.8→1.0 淡出，中间保持 1.0
  double _fadeOpacity(double frac) {
    if (frac < 0.1) return frac / 0.1;
    if (frac > 0.8) return 1.0 - (frac - 0.8) / 0.2;
    return 1.0;
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) =>
      old.time != time || old.density != density || old.color != color || old.ops != ops;
}
