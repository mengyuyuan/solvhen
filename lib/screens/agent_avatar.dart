/// Solvhen AI手机智能体 — AI 头像动画引擎 v1.1
/// PNG 精灵图方案：16 个手绘帧用于视线方向 + 眨眼动画。
/// 根据 AgentState 驱动不同的动画参数（眨眼频率、视线移动、呼吸缩放、弹跳）。
///
/// 动画系统：
/// - 眨眼（Blink）：12 步往返，支持慢速/正常/快速三种速度
/// - 视线（Glance）：周期性切换视线方向 PNG
/// - 呼吸（Breathing）：AnimationController 驱动的正弦缩放
/// - 手势（Gesture）：UIController 推送的瞬时姿态（歪头/点头/靠近等）
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ui_controller.dart';

/// 头像动画状态枚举——驱动PNG序列帧动画
enum AgentState {
  idle,
  thinking,
  coding,
  searching,
  reading,
  writing,
  speaking,
  confused,
  celebrating,
  sleeping
}

// ═══════════════════════════════════════════════
// 眨眼动画 — 帧序列定义
// ═══════════════════════════════════════════════

/// 眨眼帧名称数组（闭眼过程的 6 帧）
const _blinkFrames = [
  '闭眼动画开始',
  '闭眼五分之一',
  '闭眼五分之二',
  '闭眼五分之3',
  '闭眼五分之四',
  '闭眼五分之五',
];

/// 自然眨眼参数：10 步往返，30ms/步，闭眼保持 50ms
const _blinkStepMs = 30;
const _blinkClosedHoldMs = 50;

/// 快速眨眼（说话时）：25ms/步，无保持
const _quickBlinkStepMs = 25;

/// 慢速眨眼（思考时）：80ms/步，闭眼保持 150ms
const _slowBlinkStepMs = 80;
const _slowBlinkHoldMs = 150;

/// 将眨眼阶段 [0..11] 转换为图片资源名。
/// 0→闭眼动画开始 ... 5→闭眼五分之五 ... 11→闭眼动画开始
String _blinkFrameName(int phase) {
  if (phase <= 5) return _blinkFrames[phase];
  return _blinkFrames[11 - phase]; // 6→4, 7→3, 8→2, 9→1, 10→0
}

/// 自然眨眼序列（12 步）。
/// -1 表示"停留在帧5并额外保持"
List<int> _blinkSequence() => [0, 1, 2, 3, 4, 5, -1, 4, 3, 2, 1, 0];

// ═══════════════════════════════════════════════
// 状态配置 — 每种 AgentState 的动画参数
// ═══════════════════════════════════════════════

class _StateConfig {
  final Duration blinkInterval; // 平均眨眼间隔
  final int blinkStepMs; // 每眨眼步时长 ms
  final int blinkHoldMs; // 闭眼保持时长 ms
  final List<String> directions; // 视线方向序列（空 = 不移动）
  final int glanceStepMs; // 视线切换间隔 ms
  final bool breathing; // 是否启用呼吸缩放
  final double breathScale; // 最大缩放比例 (1.0 + breathScale)
  final int breathDurationSec; // 完整呼吸周期秒数
  final double? yBounce; // 垂直弹跳幅度（像素）

  const _StateConfig({
    required this.blinkInterval,
    this.blinkStepMs = _blinkStepMs,
    this.blinkHoldMs = _blinkClosedHoldMs,
    this.directions = const [],
    this.glanceStepMs = 300,
    this.breathing = true,
    this.breathScale = 0.02,
    this.breathDurationSec = 3,
    this.yBounce,
  });
}

/// 每种 AgentState 的动画参数映射表
const _stateConfigs = <AgentState, _StateConfig>{
  // IDLE：正常眨眼 3-5s，微呼吸，不移动视线
  AgentState.idle: _StateConfig(blinkInterval: Duration(seconds: 4)),

  // THINKING：慢速深思眨眼，偶尔视线漂移
  AgentState.thinking: _StateConfig(
    blinkInterval: Duration(seconds: 8),
    blinkStepMs: _slowBlinkStepMs,
    blinkHoldMs: _slowBlinkHoldMs,
    directions: ['右上', '中间', '左下', '正'],
    glanceStepMs: 900,
  ),

  // SPEAKING：快速频繁眨眼，眼神交流 + 偶尔向上看
  AgentState.speaking: _StateConfig(
    blinkInterval: Duration(milliseconds: 1500),
    blinkStepMs: _quickBlinkStepMs,
    blinkHoldMs: 0,
    directions: ['正', '正上'],
    glanceStepMs: 600,
    yBounce: 2.0,
  ),

  // SEARCHING：循环移动视线，不眨眼
  AgentState.searching: _StateConfig(
    blinkInterval: Duration(days: 999),
    directions: ['右上', '右', '右下', '下', '左下', '左', '左上', '正上', '中间'],
    glanceStepMs: 450,
    breathing: false,
  ),

  // CODING：极稀疏眨眼，专注向下看
  AgentState.coding: _StateConfig(
    blinkInterval: Duration(seconds: 15),
    directions: ['正', '下'],
    glanceStepMs: 3000,
    breathScale: 0.01,
    breathDurationSec: 4,
  ),

  // READING：正常眨眼，水平扫视
  AgentState.reading: _StateConfig(
    blinkInterval: Duration(seconds: 4),
    directions: ['正', '右', '正', '左'],
    glanceStepMs: 900,
  ),

  // WRITING：中等眨眼，轻微垂直弹跳
  AgentState.writing: _StateConfig(
    blinkInterval: Duration(seconds: 5),
    yBounce: 3.0,
    breathDurationSec: 2,
  ),

  // 边界状态
  AgentState.confused: _StateConfig(
    blinkInterval: Duration(seconds: 2),
    directions: ['正', '右上', '左下', '正'],
    glanceStepMs: 700,
  ),
  AgentState.celebrating: _StateConfig(
    blinkInterval: Duration(milliseconds: 800),
    blinkStepMs: _quickBlinkStepMs,
    directions: ['正', '正上'],
    glanceStepMs: 300,
    breathScale: 0.05,
    breathDurationSec: 1,
  ),
  AgentState.sleeping: _StateConfig(
    blinkInterval: Duration(days: 999),
    directions: ['下'],
    glanceStepMs: 9999,
    breathing: false,
  ),
};

// ═══════════════════════════════════════════════
// Widget
// ═══════════════════════════════════════════════

/// AI头像组件——8状态序列帧动画引擎
/// 状态：thinking/speaking/listening/idle/searching/coding/reading/writing
class AgentAvatar extends StatefulWidget {
  final double size;
  final AgentState state;
  final AvatarExpressionData? customExpr;

  const AgentAvatar({
    super.key,
    this.size = 72,
    this.state = AgentState.idle,
    this.customExpr,
  });

  @override
  State<AgentAvatar> createState() => _AgentAvatarState();
}

class _AgentAvatarState extends State<AgentAvatar>
    with TickerProviderStateMixin {
  late AnimationController _breatheCtrl;

  // ── 眨眼状态 ──
  Timer? _blinkTimer;
  Timer? _blinkStepTimer;
  int _blinkStep = -1; // -1 = 未眨眼，显示方向图片
  bool _blinkOnHold = false; // 是否在闭眼保持阶段

  // ── 视线状态 ──
  Timer? _glanceTimer;
  String _currentImage = '正';
  int _glanceIdx = 0;

  // ── 手势状态（从旧头像迁移）──
  String? _lastGesture;
  bool _gestureAnimating = false;
  bool _pendingGestureCheck = false;

  /// 获取当前状态的动画配置，未找到时回退到 idle
  _StateConfig get _cfg =>
      _stateConfigs[widget.state] ?? _stateConfigs[AgentState.idle]!;

  @override
  void initState() {
    super.initState();
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: Duration(seconds: _cfg.breathDurationSec),
    );
    _breatheCtrl.repeat(reverse: true);
    _startCycles();
  }

  @override
  void didUpdateWidget(covariant AgentAvatar old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _restartCycles();
    }
  }

  /// 重新启动所有动画循环：取消旧定时器 + 重置状态 + 启动新循环
  void _restartCycles() {
    _blinkTimer?.cancel();
    _blinkStepTimer?.cancel();
    _glanceTimer?.cancel();
    _blinkStep = -1;
    _blinkOnHold = false;
    _currentImage = '正';
    _glanceIdx = 0;

    _breatheCtrl.stop();
    _breatheCtrl.duration = Duration(seconds: _cfg.breathDurationSec);
    _breatheCtrl.repeat(reverse: true);

    _startCycles();
    if (mounted) setState(() {});
  }

  /// 启动眨眼和视线循环
  void _startCycles() {
    _scheduleBlink();
    _startGlanceCycle();
  }

  // ═══════════════════════════════════════
  // 眨眼
  // ═══════════════════════════════════════

  /// 安排下次眨眼：加上 ±30% 随机抖动，避免机械感
  void _scheduleBlink() {
    final baseMs = _cfg.blinkInterval.inMilliseconds;
    _blinkTimer?.cancel();
    // SEARCHING intentionally uses a multi-day interval to mean "do not
    // blink". Do not feed that sentinel into Random.nextInt (32-bit bound),
    // and do not clamp it into an accidental 30-second blink.
    if (baseMs >= const Duration(hours: 1).inMilliseconds) {
      _blinkTimer = null;
      return;
    }
    final factor = 0.7 + math.Random().nextDouble() * 0.6;
    final delay = (baseMs * factor).round();
    _blinkTimer =
        Timer(Duration(milliseconds: delay.clamp(200, 30000)), _startBlink);
  }

  /// 开始眨眼动画
  void _startBlink() {
    if (!mounted) return;
    _blinkStep = 0;
    _blinkOnHold = false;
    _advanceBlink();
  }

  /// 推进眨眼动画的一步
  void _advanceBlink() {
    if (!mounted) return;
    if (_blinkStep < 0) {
      _scheduleBlink();
      return;
    }

    final seq = _blinkSequence();
    if (_blinkStep >= seq.length) {
      // 眨眼完成 → 重置并安排下次
      _blinkStep = -1;
      _blinkOnHold = false;
      if (mounted) setState(() {});
      _scheduleBlink();
      return;
    }

    final idx = seq[_blinkStep];
    if (idx == -1) {
      // 闭眼保持阶段
      _blinkOnHold = true;
      if (mounted) setState(() {});
      _blinkStepTimer?.cancel();
      _blinkStepTimer = Timer(Duration(milliseconds: _cfg.blinkHoldMs), () {
        _blinkOnHold = false;
        _blinkStep++;
        _advanceBlink();
      });
    } else {
      _blinkOnHold = false;
      if (mounted) setState(() {});
      _blinkStepTimer?.cancel();
      _blinkStepTimer = Timer(Duration(milliseconds: _cfg.blinkStepMs), () {
        _blinkStep++;
        _advanceBlink();
      });
    }
  }

  // ═══════════════════════════════════════
  // 视线移动
  // ═══════════════════════════════════════

  /// 启动视线方向循环定时器
  void _startGlanceCycle() {
    final dirs = _cfg.directions;
    if (dirs.isEmpty) return;

    _glanceTimer?.cancel();
    _glanceTimer =
        Timer.periodic(Duration(milliseconds: _cfg.glanceStepMs), (_) {
      if (!mounted) return;
      _glanceIdx = (_glanceIdx + 1) % dirs.length;
      _currentImage = dirs[_glanceIdx];
      if (mounted) setState(() {});
    });
  }

  // ═══════════════════════════════════════
  // 图片选择：眨眼优先 → 闭眼保持 → 视线方向
  // ═══════════════════════════════════════

  String get _displayImage {
    if (_blinkStep >= 0 && !_blinkOnHold) {
      return _blinkFrameName(_blinkStep);
    }
    if (_blinkOnHold) return '闭眼五分之五';
    return _currentImage;
  }

  // ═══════════════════════════════════════
  // 手势（从旧几何头像迁移）
  // ═══════════════════════════════════════

  /// 检查 UIController 是否有待处理的手势
  void _checkGesture() {
    final ui = UIController();
    if (ui.gesture != null && !_gestureAnimating) {
      _lastGesture = ui.gesture;
      _gestureAnimating = true;
      _playGesture(ui.gesture!);
    }
  }

  /// 播放手势动画：设置瞬时变换，500ms 后重置
  void _playGesture(String gesture) {
    // 验证手势类型是否有效
    switch (gesture) {
      case 'tilt_head':
      case 'nod':
      case 'shrug':
      case 'lean_in':
      case 'step_back':
      case 'sigh':
      case 'waiting':
        break;
      default:
        _gestureAnimating = false;
        return;
    }

    setState(() {});
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _gestureAnimating = false;
        setState(() {});
      }
    });
  }

  // ═══════════════════════════════════════
  // 构建
  // ═══════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // ⚠️ 检查手势：使用 _pendingGestureCheck 标志 + addPostFrameCallback 避免 build() 中修改状态
    if (UIController().gesture != null && !_pendingGestureCheck) {
      _pendingGestureCheck = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingGestureCheck = false;
        _checkGesture();
      });
    }

    // 手势变换参数
    double gScale = 1.0, gRotate = 0.0, gTranslateY = 0.0;
    if (_gestureAnimating) {
      switch (_lastGesture) {
        case 'lean_in':
          gScale = 1.12;
          break;
        case 'step_back':
          gScale = 0.94;
          break;
        case 'sigh':
          gScale = 0.97;
          break;
        case 'tilt_head':
          gRotate = 0.14;
          break;
        case 'waiting':
          gRotate = -0.05;
          break;
        case 'nod':
          gTranslateY = -5;
          break;
      }
    }

    final hasMotion =
        _cfg.breathing || _cfg.yBounce != null || _gestureAnimating;

    // 头像源图为 1254px。按实际显示像素解码，避免 20/32px 小头像的
    // 每一帧都占用数 MB GPU 内存；gaplessPlayback 在换帧期间保留上一帧，
    // 防止 Android 上短暂出现灰色占位块。
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheSize = (widget.size * devicePixelRatio).ceil().clamp(24, 320);
    Widget avatar = Image.asset(
      'assets/avatars/$_displayImage.png',
      width: widget.size,
      height: widget.size,
      cacheWidth: cacheSize,
      cacheHeight: cacheSize,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => Image.asset(
        'assets/avatars/正.png',
        width: widget.size,
        height: widget.size,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );

    // 需要运动时包裹 AnimatedBuilder 实现呼吸+弹跳+手势合成
    if (hasMotion) {
      avatar = AnimatedBuilder(
        animation: _breatheCtrl,
        builder: (_, child) {
          final t = _breatheCtrl.value;
          final s = _cfg.breathing
              ? 1.0 + math.sin(t * 2 * math.pi) * _cfg.breathScale
              : 1.0;
          final bounceY = _cfg.yBounce != null
              ? math.sin(t * 2 * math.pi) * _cfg.yBounce!
              : 0.0;
          return Transform.translate(
            offset: Offset(0, bounceY + gTranslateY),
            child: Transform.rotate(
              angle: gRotate,
              child: Transform.scale(
                scale: s * gScale,
                child: child,
              ),
            ),
          );
        },
        child: avatar,
      );
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: avatar,
    );
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blinkStepTimer?.cancel();
    _glanceTimer?.cancel();
    _breatheCtrl.dispose();
    super.dispose();
  }
}
