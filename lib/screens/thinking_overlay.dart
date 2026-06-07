// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 思考动画覆盖层——AI思考时的加载动画指示器
// ═══════════════════════════════════════════════════════════════

library;


import 'dart:async';
import 'package:flutter/material.dart';
import 'agent_avatar.dart';

String _stateLabel(AgentState s) {
  switch (s) {
    case AgentState.thinking:  return '思考中...';
    case AgentState.coding:    return '写代码...';
    case AgentState.searching: return '搜索中...';
    case AgentState.reading:   return '阅读中...';
    case AgentState.writing:   return '写入文件...';
    case AgentState.speaking:  return '回复中...';
    default: return '';
  }
}

IconData? _stateIcon(AgentState s) {
  switch (s) {
    case AgentState.thinking:  return Icons.psychology_outlined;
    case AgentState.coding:    return Icons.code;
    case AgentState.searching: return Icons.travel_explore;
    case AgentState.reading:   return Icons.menu_book_outlined;
    case AgentState.writing:   return Icons.edit_note;
    case AgentState.speaking:  return Icons.mic_none;
    default: return null;
  }
}

/// AI思考时的加载动画覆盖层——脉冲点+文字提示
/// ⚠️ build()内禁止修改AnimationController状态
class ThinkingOverlay extends StatefulWidget {
  final AgentState state;
  final Color accentColor;
  final String? statusText;
  final DateTime? sendStartedAt;

  const ThinkingOverlay({super.key, required this.state, required this.accentColor, this.statusText, this.sendStartedAt});

  bool get _visible => state != AgentState.idle && state != AgentState.sleeping;

  @override
  State<ThinkingOverlay> createState() => _ThinkingOverlayState();
}

class _ThinkingOverlayState extends State<ThinkingOverlay> {
  int _elapsed = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _manageTimer();
  }

  @override
  void didUpdateWidget(ThinkingOverlay old) {
    super.didUpdateWidget(old);
    if (widget.sendStartedAt != old.sendStartedAt) {
      _elapsed = 0;
    }
    _manageTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _manageTimer() {
    final shouldTick = widget._visible && widget.sendStartedAt != null;
    if (shouldTick) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted &&
            widget._visible &&
            widget.sendStartedAt != null) {
          final secs = DateTime.now().difference(widget.sendStartedAt!).inSeconds;
          if (secs != _elapsed) {
            setState(() => _elapsed = secs);
          }
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  String get _label {
    final base = widget.statusText != null && widget.statusText!.isNotEmpty
        ? widget.statusText!
        : _stateLabel(widget.state);
    if (widget.sendStartedAt == null) return base;
    final secs = DateTime.now().difference(widget.sendStartedAt!).inSeconds;
    if (secs > 0) return '$base (${secs}s)';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    // _elapsed is updated by the timer callback, not here.
    // The timer fires every second; build() just reads the value.

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget._visible ? 1.0 : 0.0,
        child: widget._visible
            ? Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: widget.accentColor.withValues(alpha: 0.06),
                  border: Border(bottom: BorderSide(color: widget.accentColor.withValues(alpha: 0.1), width: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AnimatedDot(color: widget.accentColor),
                    const SizedBox(width: 8),
                    if (_stateIcon(widget.state) != null) ...[
                      Icon(_stateIcon(widget.state), size: 14, color: widget.accentColor),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      _label,
                      style: TextStyle(fontSize: 12, color: widget.accentColor, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _AnimatedDot extends StatefulWidget {
  final Color color;
  const _AnimatedDot({required this.color});

  @override
  State<_AnimatedDot> createState() => _AnimatedDotState();
}

class _AnimatedDotState extends State<_AnimatedDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _ctrl.repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final delay = i * 0.2;
          final opacity = ((_ctrl.value - delay) % 1.0).clamp(0.0, 0.6) * 1.5;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: Container(
              width: 5, height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: opacity.clamp(0.1, 0.9)),
              ),
            ),
          );
        }),
      ),
    );
  }
}
