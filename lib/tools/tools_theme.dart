/// Solvhen AI手机智能体 — 主题与配色工具
/// 通过全局 ThemeNotifier 单例修改界面主题色、明暗模式、气泡颜色。
/// 无需 WidgetRef，工具可直接调用。
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'tool_registry.dart';
import '../theme/theme_provider.dart';
import '../screens/ui_controller.dart';

/// 注册主题配色工具
/// 工具：set_theme(AI修改应用全局配色)/get_theme(查看当前配色)
/// 可修改：50+语义色属性（背景/文字/强调/气泡/危险/警告/成功等）
void registerThemeTools() {
  final registry = ToolRegistry();
  final theme = ThemeNotifier();

  // ── set_theme_color — 修改界面主题色 ──
  registry.register(ToolEntry(
    name: 'set_theme_color',
    toolset: 'theme',
    schema: {
      'name': 'set_theme_color',
      'description': '修改界面主题色。支持颜色名称或十六进制，如 pink, #FF69B4。',
      'parameters': {
        'type': 'object',
        'properties': {
          'color': {
            'type': 'string',
            'description': '颜色名称或十六进制 (#RRGGBB)',
          }
        },
        'required': ['color'],
      }
    },
    handler: (args) async {
      try {
        final color = args['color'] as String;
        final ok = theme.setAccentColor(color);
        return jsonEncode({
          'success': ok,
          'color': color,
          'error': ok ? null : '无法解析颜色 "$color"',
        });
      } catch (e) {
        return jsonEncode({'success': false, 'error': '设置失败: ${e.toString().substring(0, 80)}'});
      }
    },
  ));

  // ── set_theme_mode — 切换明暗模式 ──
  registry.register(ToolEntry(
    name: 'set_theme_mode',
    toolset: 'theme',
    schema: {
      'name': 'set_theme_mode',
      'description': '切换明暗模式。',
      'parameters': {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['light', 'dark']},
        },
        'required': ['mode'],
      }
    },
    handler: (args) async {
      final mode = args['mode'] as String;
      theme.setBrightness(mode);
      return jsonEncode({'success': true, 'mode': mode});
    },
  ));

  // ── set_bubble_color — 修改聊天气泡颜色 ──
  registry.register(ToolEntry(
    name: 'set_bubble_color',
    toolset: 'theme',
    schema: {
      'name': 'set_bubble_color',
      'description': '修改气泡颜色。target: "me"(对方气泡) | "self"(自己气泡) | 不传默认改自己的。支持颜色名或十六进制如 pink/#FF69B4。"reset" 恢复默认。',
      'parameters': {
        'type': 'object',
        'properties': {
          'color': {'type': 'string', 'description': '颜色名/#RRGGBB，reset=恢复默认'},
          'target': {'type': 'string', 'enum': ['self', 'me'], 'description': 'self=自己的气泡, me=对方的气泡。默认self。'},
        },
        'required': ['color'],
      }
    },
    handler: (args) async {
      try {
        final colorStr = args['color'] as String;
        final target = args['target'] as String? ?? 'self';
        final ui = UIController();
        // reset：恢复默认气泡颜色
        if (colorStr.toLowerCase() == 'reset') {
          if (target == 'me') {
            ui.setUserBubbleColor(null);
          } else {
            ui.setBubbleColor(null);
          }
          return jsonEncode({'success': true, 'mode': 'reset', 'target': target});
        }
        final color = _parseColor(colorStr);
        if (color == null) {
          return jsonEncode({'success': false, 'error': '无法解析颜色 "$colorStr"'});
        }
        if (target == 'me') {
          ui.setUserBubbleColor(color);
        } else {
          ui.setBubbleColor(color);
        }
        return jsonEncode({'success': true, 'color': colorStr, 'target': target});
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString().substring(0, 80)});
      }
    },
  ));
}

/// 从字符串解析 Flutter Color，支持 hex 和颜色名称。
/// 注意：与 tools_ui.dart 中的 _parseColor 功能高度重叠，
/// 但此版本额外支持颜色名映射（如 pink→0xFFFF69B4）。
/// 后续应将两者合并到 tool_utils.dart 中统一管理。
///
/// 已知限制：不支持 3 位 hex 简写（如 #FFF），
/// 会将其当作无 alpha 的 3 字节解析，结果错误。
Color? _parseColor(String s) {
  try {
    final h = s.replaceFirst('#', '');
    // 6位hex补全不透明alpha
    final full = h.length == 6 ? 'FF$h' : h;
    return Color(int.parse(full, radix: 16));
  } catch (_) {
    // hex 解析失败 → 查颜色名称映射表
    const named = {
      'pink': 0xFFFF69B4, 'red': 0xFFFF0000, 'orange': 0xFFFF9500,
      'yellow': 0xFFFFD700, 'green': 0xFF00FF41, 'teal': 0xFF00FFAA,
      'blue': 0xFF4A9EFF, 'purple': 0xFFAF52DE, 'white': 0xFFFFFFFF,
      'black': 0xFF000000, 'gray': 0xFF888888, 'grey': 0xFF888888,
      'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF, 'gold': 0xFFFFD700,
    };
    final c = named[s.toLowerCase()];
    return c != null ? Color(c) : null;
  }
}
