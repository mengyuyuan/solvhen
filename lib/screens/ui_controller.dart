// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// UI控制器——屏幕情绪/背景效果/粒子密度/颜色主题的状态管理
// ═══════════════════════════════════════════════════════════════

library;

/// V2: customExpression, animation state, typewriter all integrated.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/database_service.dart';

class AnimationStep {
  final String target;
  final List<Keyframe> keyframes;
  final String? curve;
  const AnimationStep(
      {required this.target, required this.keyframes, this.curve});
}

class Keyframe {
  final String prop;
  final double from;
  final double to;
  final int duration;
  final String? curve;
  const Keyframe(
      {required this.prop,
      required this.from,
      required this.to,
      this.duration = 300,
      this.curve});
}

class ParticleConfig {
  final String shape;
  final Color color;
  final int count;
  final double spread;
  final int duration;
  final String path;
  const ParticleConfig({
    this.shape = 'dot',
    this.color = const Color(0xFFFF6B9D),
    this.count = 20,
    this.spread = 1.0,
    this.duration = 2000,
    this.path = 'fly_up',
  });
}

class ScreenMood {
  final Color? primary;
  final Color? accent;
  final Color? bgTop;
  final Color? bgBottom;
  final double? vignetteIntensity;
  final Color? vignetteColor;
  final double? particleDensity;
  final double? particleSpeed;
  final String? bgStyle;
  final Color? particleColor;
  final List<Map<String, dynamic>>? bgEffects;

  const ScreenMood({
    this.primary,
    this.accent,
    this.bgTop,
    this.bgBottom,
    this.vignetteIntensity,
    this.vignetteColor,
    this.particleDensity,
    this.particleSpeed,
    this.bgStyle,
    this.particleColor,
    this.bgEffects,
  });

  ScreenMood merge(ScreenMood other) => ScreenMood(
        primary: other.primary ?? primary,
        accent: other.accent ?? accent,
        bgTop: other.bgTop ?? bgTop,
        bgBottom: other.bgBottom ?? bgBottom,
        vignetteIntensity: other.vignetteIntensity ?? vignetteIntensity,
        vignetteColor: other.vignetteColor ?? vignetteColor,
        particleDensity: other.particleDensity ?? particleDensity,
        particleSpeed: other.particleSpeed ?? particleSpeed,
        bgStyle: other.bgStyle ?? bgStyle,
        particleColor: other.particleColor ?? particleColor,
        bgEffects: other.bgEffects ?? bgEffects,
      );

  Map<String, dynamic> toJson() => {
        if (primary != null)
          'primary':
              '#${primary!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        if (accent != null)
          'accent': '#${accent!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        if (bgTop != null)
          'bgTop': '#${bgTop!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        if (bgBottom != null)
          'bgBottom':
              '#${bgBottom!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        if (vignetteIntensity != null) 'vignetteIntensity': vignetteIntensity,
        if (vignetteColor != null)
          'vignetteColor':
              '#${vignetteColor!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        if (particleDensity != null) 'particleDensity': particleDensity,
        if (particleSpeed != null) 'particleSpeed': particleSpeed,
        if (bgStyle != null) 'bgStyle': bgStyle,
        if (particleColor != null)
          'particleColor':
              '#${particleColor!.toARGB32().toRadixString(16).padLeft(8, '0')}',
        // bgEffects intentionally excluded — transient visual effects should not survive restarts
      };

  factory ScreenMood.fromJson(Map<String, dynamic> json) => ScreenMood(
        primary: _parseColor(json['primary']),
        accent: _parseColor(json['accent']),
        bgTop: _parseColor(json['bgTop']),
        bgBottom: _parseColor(json['bgBottom']),
        vignetteIntensity: (json['vignetteIntensity'] as num?)?.toDouble(),
        vignetteColor: _parseColor(json['vignetteColor']),
        particleDensity: (json['particleDensity'] as num?)?.toDouble(),
        particleSpeed: (json['particleSpeed'] as num?)?.toDouble(),
        bgStyle: json['bgStyle'] as String?,
        particleColor: _parseColor(json['particleColor']),
        bgEffects: null, // bgEffects are transient — never restore from DB
      );

  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    try {
      final h = hex.replaceFirst('#', '');
      final full = h.length == 6 ? 'FF$h' : h;
      return Color(int.parse(full, radix: 16));
    } catch (_) {
      return null;
    }
  }
}

/// Simple expression data for avatar control.
class AvatarExpressionData {
  final double? eyeCurveL, eyeCurveR, pupilSize, mouthCurve;
  final String? mouthStyle;
  final double? browAngleL, browAngleR;
  final double? glowIntensity;
  final Color? glowColor;
  final double? particleDensity;

  const AvatarExpressionData({
    this.eyeCurveL,
    this.eyeCurveR,
    this.pupilSize,
    this.mouthCurve,
    this.mouthStyle,
    this.browAngleL,
    this.browAngleR,
    this.glowIntensity,
    this.glowColor,
    this.particleDensity,
  });

  AvatarExpressionData merge(AvatarExpressionData other) =>
      AvatarExpressionData(
        eyeCurveL: other.eyeCurveL ?? eyeCurveL,
        eyeCurveR: other.eyeCurveR ?? eyeCurveR,
        pupilSize: other.pupilSize ?? pupilSize,
        mouthCurve: other.mouthCurve ?? mouthCurve,
        mouthStyle: other.mouthStyle ?? mouthStyle,
        browAngleL: other.browAngleL ?? browAngleL,
        browAngleR: other.browAngleR ?? browAngleR,
        glowIntensity: other.glowIntensity ?? glowIntensity,
        glowColor: other.glowColor ?? glowColor,
        particleDensity: other.particleDensity ?? particleDensity,
      );
}

/// UI控制器——屏幕情绪/背景效果/粒子密度/颜色主题的状态管理
/// ⚠️ toJson不序列化bgEffects（防持久化泄漏）
class UIController extends ChangeNotifier {
  static final UIController _instance = UIController._();
  factory UIController() => _instance;
  UIController._() {
    Future.microtask(_loadFromDB);
  }

  Future<void> _loadFromDB() async {
    try {
      final config = await DB.getConfig();
      final serialized = config['ui_mood'];
      if (serialized != null && serialized.isNotEmpty) {
        final json = jsonDecode(serialized) as Map<String, dynamic>;
        _mood = ScreenMood.fromJson(json);
      }
      // Load bubble colors
      final bubbleHex = config['bubble_color'];
      if (bubbleHex != null && bubbleHex.isNotEmpty) {
        _bubbleColor = _parseHexColor(bubbleHex);
      }
      final userBubbleHex = config['user_bubble_color'];
      if (userBubbleHex != null && userBubbleHex.isNotEmpty) {
        _userBubbleColor = _parseHexColor(userBubbleHex);
      }
      notifyListeners();
    } catch (_) {}
  }

  static Color? _parseHexColor(String? hex) {
    if (hex == null) return null;
    try {
      final h = hex.replaceFirst('#', '');
      final full = h.length == 6 ? 'FF$h' : h;
      return Color(int.parse(full, radix: 16));
    } catch (_) {
      return null;
    }
  }

  bool _moodDirty = false;

  Future<void> _saveMoodToDB() async {
    try {
      await DB.setConfig('ui_mood', jsonEncode(_mood.toJson()));
      _moodDirty = false;
    } catch (e) {
      _moodDirty = true;
      // In release mode debugPrint is stripped, so use print for crash/stability logging
      try {
        if (kDebugMode) debugPrint('[UIController] _saveMoodToDB failed: $e');
      } catch (_) {}
    }
  }

  AnimationStep? _currentAnimation;
  AnimationStep? get currentAnimation => _currentAnimation;

  ScreenMood _mood = const ScreenMood();
  ScreenMood get mood => _mood;

  ParticleConfig? _particles;
  ParticleConfig? get particles => _particles;
  int _particleBurst = 0;
  int get particleBurst => _particleBurst;

  String? _gesture;
  String? get gesture => _gesture;

  bool _typewriterMode = false;
  int _typewriterSpeed = 30;
  bool get typewriterMode => _typewriterMode;
  int get typewriterSpeed => _typewriterSpeed;

  // Avatar expression — moved from tools_ui.dart module-level
  AvatarExpressionData? _expression;
  AvatarExpressionData? get expression => _expression;

  /// Animate target element.
  void animate(AnimationStep step) {
    _currentAnimation = step;
    notifyListeners();
    final maxDur = step.keyframes.fold<int>(0, (s, k) => s + k.duration);
    Future.delayed(Duration(milliseconds: maxDur + 100), () {
      if (_currentAnimation == step) {
        _currentAnimation = null;
        notifyListeners();
      }
    });
  }

  void setScreenMood(ScreenMood mood) {
    // If previous save failed, retry now before applying new changes
    if (_moodDirty) {
      _saveMoodToDB();
    }
    final merged = _mood.merge(mood);
    if (identical(merged, _mood)) return; // nothing changed
    _mood = merged;
    notifyListeners();
    _saveMoodToDB();
  }

  void spawnParticles(ParticleConfig config) {
    _particles = config;
    _particleBurst++;
    notifyListeners();
    Future.delayed(Duration(milliseconds: config.duration + 100), () {
      _particles = null;
      notifyListeners();
    });
  }

  void setGesture(String? gesture) {
    _gesture = gesture;
    notifyListeners();
    if (gesture != null) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (_gesture == gesture) {
          _gesture = null;
          notifyListeners();
        }
      });
    }
  }

  void setTypewriter(bool on, {int speed = 30}) {
    _typewriterMode = on;
    _typewriterSpeed = speed;
    notifyListeners();
  }

  void setExpression(AvatarExpressionData expr) {
    _expression = (_expression ?? const AvatarExpressionData()).merge(expr);
    if (kDebugMode) {
      debugPrint(
          '[Solvhen:expr] eyeL=${_expression!.eyeCurveL} eyeR=${_expression!.eyeCurveR} mouth=${_expression!.mouthCurve} browL=${_expression!.browAngleL} glow=${_expression!.glowIntensity}');
    }
    notifyListeners();
  }

  // ── Bubble color ──
  Color? _bubbleColor;
  Color? get bubbleColor => _bubbleColor;
  void setBubbleColor(Color? c) {
    _bubbleColor = c;
    notifyListeners();
    _saveBubbleColors();
  }

  Color? _userBubbleColor;
  Color? get userBubbleColor => _userBubbleColor;
  void setUserBubbleColor(Color? c) {
    _userBubbleColor = c;
    notifyListeners();
    _saveBubbleColors();
  }

  void _saveBubbleColors() {
    try {
      if (_bubbleColor != null) {
        DB.setConfig('bubble_color',
            '#${_bubbleColor!.toARGB32().toRadixString(16).padLeft(8, '0')}');
      } else {
        DB.setConfig('bubble_color', '');
      }
      if (_userBubbleColor != null) {
        DB.setConfig('user_bubble_color',
            '#${_userBubbleColor!.toARGB32().toRadixString(16).padLeft(8, '0')}');
      } else {
        DB.setConfig('user_bubble_color', '');
      }
    } catch (_) {}
  }
}
