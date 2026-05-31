/// Theme tools — uses global ThemeNotifier singleton (no WidgetRef needed).
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'tool_registry.dart';
import '../theme/theme_provider.dart';
import '../screens/ui_controller.dart';

void registerThemeTools() {
  final registry = ToolRegistry();
  final theme = ThemeNotifier();

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

Color? _parseColor(String s) {
  try {
    final h = s.replaceFirst('#', '');
    final full = h.length == 6 ? 'FF$h' : h;
    return Color(int.parse(full, radix: 16));
  } catch (_) {
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
