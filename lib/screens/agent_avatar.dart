/// PNG-based avatar for Solvhen v1.1.
/// Uses 16 hand-crafted frames for eye direction + blink animation.
/// Replaces the old CustomPaint geometric avatar.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ui_controller.dart';

enum AgentState {
  idle, thinking, coding, searching, reading, writing,
  speaking, confused, celebrating, sleeping
}

// ═══════════════════════════════════════════════
// BLINK ANIMATION — frame sequence definition
// ═══════════════════════════════════════════════
const _blinkFrames = [
  '闭眼动画开始', '闭眼五分之一', '闭眼五分之二',
  '闭眼五分之3', '闭眼五分之四', '闭眼五分之五',
];

/// Natural blink: 10-step round trip, 30ms/step, 50ms hold at closed.
const _blinkStepMs = 30;
const _blinkClosedHoldMs = 50;

/// Quick blink (speaking): 25ms/step, no hold.
const _quickBlinkStepMs = 25;

/// Slow blink (thinking): 80ms/step, 150ms hold.
const _slowBlinkStepMs = 80;
const _slowBlinkHoldMs = 150;

/// Convert phase [0..11] to image asset name.
/// 0→闭眼动画开始 ... 5→闭眼五分之五 ... 11→闭眼动画开始
String _blinkFrameName(int phase) {
  if (phase <= 5) return _blinkFrames[phase];
  return _blinkFrames[11 - phase]; // 6→4, 7→3, 8→2, 9→1, 10→0, 11→不会到11
}

/// Blink phase progression for natural blink (12 steps).
/// Returns list of (frameIndex, holdMs).
List<int> _blinkSequence() => [0, 1, 2, 3, 4, 5, -1, 4, 3, 2, 1, 0];
// -1 means "stay on frame 5 with extra hold"

// ═══════════════════════════════════════════════
// STATE CONFIG — per-state animation parameters
// ═══════════════════════════════════════════════

class _StateConfig {
  final Duration blinkInterval;  // avg time between blinks
  final int blinkStepMs;         // ms per blink animation step
  final int blinkHoldMs;         // ms to hold eyes closed
  final List<String> directions; // glance direction sequence (empty = no glance)
  final int glanceStepMs;        // ms per direction change
  final bool breathing;          // subtle scale oscillation
  final double breathScale;      // max scale factor (1.0 + breathScale)
  final int breathDurationSec;   // full cycle duration
  final double? yBounce;         // vertical bounce amplitude in pixels

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

const _stateConfigs = <AgentState, _StateConfig>{
  // IDLE: normal blink every 3-5s, subtle breathing, no eye movement
  AgentState.idle: _StateConfig(blinkInterval: Duration(seconds: 4)),

  // THINKING: slow deliberate blink, occasional eye drift
  AgentState.thinking: _StateConfig(
    blinkInterval: Duration(seconds: 8),
    blinkStepMs: _slowBlinkStepMs,
    blinkHoldMs: _slowBlinkHoldMs,
    directions: ['右上', '中间', '左下', '正'],
    glanceStepMs: 900,
  ),

  // SPEAKING: fast frequent blinks, eye contact with occasional glance up
  AgentState.speaking: _StateConfig(
    blinkInterval: Duration(milliseconds: 1500),
    blinkStepMs: _quickBlinkStepMs,
    blinkHoldMs: 0,
    directions: ['正', '正上'],
    glanceStepMs: 600,
    yBounce: 2.0,
  ),

  // SEARCHING: cycling through directions, NO blink
  AgentState.searching: _StateConfig(
    blinkInterval: Duration(days: 999),
    directions: ['右上', '右', '右下', '下', '左下', '左', '左上', '正上', '中间'],
    glanceStepMs: 450,
    breathing: false,
  ),

  // CODING: very rare blink, focused downward glance
  AgentState.coding: _StateConfig(
    blinkInterval: Duration(seconds: 15),
    directions: ['正', '下'],
    glanceStepMs: 3000,
    breathScale: 0.01,
    breathDurationSec: 4,
  ),

  // READING: normal blink, horizontal scan
  AgentState.reading: _StateConfig(
    blinkInterval: Duration(seconds: 4),
    directions: ['正', '右', '正', '左'],
    glanceStepMs: 900,
  ),

  // WRITING: rare blink, subtle vertical bob
  AgentState.writing: _StateConfig(
    blinkInterval: Duration(seconds: 5),
    yBounce: 3.0,
    breathDurationSec: 2,
  ),

  // Edge states
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
// WIDGET
// ═══════════════════════════════════════════════

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

class _AgentAvatarState extends State<AgentAvatar> with TickerProviderStateMixin {
  late AnimationController _breatheCtrl;

  // Blink
  Timer? _blinkTimer;
  Timer? _blinkStepTimer;
  int _blinkStep = -1; // -1 = not blinking, use direction image
  bool _blinkOnHold = false;

  // Direction
  Timer? _glanceTimer;
  String _currentImage = '正';
  int _glanceIdx = 0;

  // Gesture (ported from old avatar)
  String? _lastGesture;
  bool _gestureAnimating = false;
  bool _pendingGestureCheck = false;

  _StateConfig get _cfg => _stateConfigs[widget.state] ?? _stateConfigs[AgentState.idle]!;

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

  void _startCycles() {
    _scheduleBlink();
    _startGlanceCycle();
  }

  // ═══════════════════════════════════════
  // BLINK
  // ═══════════════════════════════════════

  void _scheduleBlink() {
    final baseMs = _cfg.blinkInterval.inMilliseconds;
    // Add ±30% random jitter so blinks don't look mechanical
    final jitter = (baseMs * 0.3).round();
    final delay = baseMs + math.Random().nextInt(jitter * 2) - jitter;
    _blinkTimer?.cancel();
    _blinkTimer = Timer(Duration(milliseconds: delay.clamp(200, 30000)), _startBlink);
  }

  void _startBlink() {
    if (!mounted) return;
    _blinkStep = 0;
    _blinkOnHold = false;
    _advanceBlink();
  }

  void _advanceBlink() {
    if (!mounted) return;
    if (_blinkStep < 0) {
      _scheduleBlink();
      return;
    }

    final seq = _blinkSequence();
    if (_blinkStep >= seq.length) {
      // Blink complete
      _blinkStep = -1;
      _blinkOnHold = false;
      if (mounted) setState(() {});
      _scheduleBlink();
      return;
    }

    final idx = seq[_blinkStep];
    if (idx == -1) {
      // Hold at closed
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
  // GLANCE / EYE DIRECTION
  // ═══════════════════════════════════════

  void _startGlanceCycle() {
    final dirs = _cfg.directions;
    if (dirs.isEmpty) return;

    _glanceTimer?.cancel();
    _glanceTimer = Timer.periodic(Duration(milliseconds: _cfg.glanceStepMs), (_) {
      if (!mounted) return;
      _glanceIdx = (_glanceIdx + 1) % dirs.length;
      _currentImage = dirs[_glanceIdx];
      if (mounted) setState(() {});
    });
  }

  // ═══════════════════════════════════════
  // IMAGE RESOLUTION
  // ═══════════════════════════════════════

  String get _displayImage {
    if (_blinkStep >= 0 && !_blinkOnHold) {
      return _blinkFrameName(_blinkStep);
    }
    if (_blinkOnHold) return '闭眼五分之五';
    return _currentImage;
  }

  // ═══════════════════════════════════════
  // GESTURE (ported)
  // ═══════════════════════════════════════

  void _checkGesture() {
    final ui = UIController();
    if (ui.gesture != null && !_gestureAnimating) {
      _lastGesture = ui.gesture;
      _gestureAnimating = true;
      _playGesture(ui.gesture!);
    }
  }

  void _playGesture(String gesture) {
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
  // BUILD
  // ═══════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // Check for gestures via post-frame callback
    if (UIController().gesture != null && !_pendingGestureCheck) {
      _pendingGestureCheck = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingGestureCheck = false;
        _checkGesture();
      });
    }

    // Gesture scale override (simplified — just set transform, reset after delay)
    double gScale = 1.0, gRotate = 0.0, gTranslateY = 0.0;
    if (_gestureAnimating) {
      switch (_lastGesture) {
        case 'lean_in': gScale = 1.12; break;
        case 'step_back': gScale = 0.94; break;
        case 'sigh': gScale = 0.97; break;
        case 'tilt_head': gRotate = 0.14; break;
        case 'waiting': gRotate = -0.05; break;
        case 'nod': gTranslateY = -5; break;
      }
    }

    // Combined breathing + bounce animation
    final hasMotion = _cfg.breathing || _cfg.yBounce != null || _gestureAnimating;

    Widget avatar = Image.asset(
      'assets/avatars/${_displayImage}.png',
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Image.asset(
        'assets/avatars/正.png',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
      ),
    );

    if (hasMotion) {
      avatar = AnimatedBuilder(
        animation: _breatheCtrl,
        builder: (_, child) {
          final t = _breatheCtrl.value;
          final s = _cfg.breathing ? 1.0 + math.sin(t * 2 * math.pi) * _cfg.breathScale : 1.0;
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
