/// UI control tools — agent freely modifies its own interface.
/// Tools: animate, draw_expression, spawn_particle, modify_appearance,
/// screen_mood, layout_gesture, typewriter_reveal
library;

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tool_registry.dart';
import 'tool_utils.dart';
import '../screens/ui_controller.dart';
import '../screens/webview_canvas.dart';
import 'package:flutter/material.dart';

void registerUITools() {
  final registry = ToolRegistry();
  final ui = UIController();

  registry.register(ToolEntry(
    name: 'animate',
    toolset: 'ui',
    schema: {
      'name': 'animate',
      'description': '''对 UI 元素执行关键帧动画序列。根据你的性格自由编写动画。

target: avatar | input_bar | backdrop | title
keyframes: [{prop, from, to, duration, curve}, ...]
prop: scale | rotate | x | y | opacity | blur
curve: easeIn | easeOut | easeInOut | linear | bounce

例: 被夸了害羞 → animate("avatar", [{prop:"scale",from:1,to:1.15,dur:200},{prop:"rotate",from:0,to:4,dur:100},{prop:"rotate",from:4,to:-3,dur:100},{prop:"scale",from:1.15,to:1,dur:200}])''',
      'parameters': {
        'type': 'object',
        'properties': {
          'target': {'type': 'string', 'description': '目标元素: avatar, input_bar, backdrop, title'},
          'keyframes': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'prop': {'type': 'string', 'enum': ['scale', 'rotate', 'x', 'y', 'opacity', 'blur']},
                'from': {'type': 'number'},
                'to': {'type': 'number'},
                'duration': {'type': 'integer', 'description': '毫秒，默认300'},
                'curve': {'type': 'string', 'enum': ['easeIn', 'easeOut', 'easeInOut', 'linear', 'bounce']},
              },
              'required': ['prop', 'from', 'to'],
            },
          },
        },
        'required': ['target', 'keyframes'],
      },
    },
    handler: (args) async {
      final target = parseArgString(args['target']);
      final kfs = parseArgList(args['keyframes']).map((k) {
        final m = k as Map<String, dynamic>;
        return Keyframe(
          prop: parseArgString(m['prop']),
          from: parseArgDouble(m['from'], 0),
          to: parseArgDouble(m['to'], 1),
          duration: parseArgOptionalInt(m['duration']) ?? 300,
          curve: m['curve'] as String?,
        );
      }).toList();
      ui.animate(AnimationStep(target: target, keyframes: kfs));
      return jsonEncode({'animated': true, 'target': target, 'steps': kfs.length});
    },
  ));

  registry.register(ToolEntry(
    name: 'draw_expression',
    toolset: 'ui',
    schema: {
      'name': 'draw_expression',
      'description': '''在头像画布上绘制表情。用操作序列控制眼睛、嘴巴、眉毛、光晕。

commands: [{op, ...}, ...]
支持: eye_left(curve), eye_right(curve), mouth(curve, style),
       brow_left(angle), brow_right(angle), glow(intensity, color),
       particles(density)

例: 温柔表情 → draw_expression([{op:"eye_left",curve:0.2},{op:"mouth",curve:0.3,style:"smirk"},{op:"glow",intensity:0.2,color:"#ff6b9d"}])''',
      'parameters': {
        'type': 'object',
        'properties': {
          'commands': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'op': {'type': 'string', 'enum': ['eye_left', 'eye_right', 'mouth', 'brow_left', 'brow_right', 'glow', 'particles']},
              },
              'required': ['op'],
            },
          },
        },
        'required': ['commands'],
      },
    },
    handler: (args) async {
      final cmds = parseArgList(args['commands']);
      var expr = const AvatarExpressionData();
      for (final c in cmds) {
        final m = c as Map<String, dynamic>;
        switch (parseArgString(m['op'])) {
          case 'eye_left':
            expr = expr.merge(AvatarExpressionData(eyeCurveL: (m['curve'] as num?)?.toDouble()));
            break;
          case 'eye_right':
            expr = expr.merge(AvatarExpressionData(eyeCurveR: (m['curve'] as num?)?.toDouble()));
            break;
          case 'mouth':
            expr = expr.merge(AvatarExpressionData(
              mouthCurve: (m['curve'] as num?)?.toDouble(),
              mouthStyle: m['style'] as String?,
            ));
            break;
          case 'brow_left':
            expr = expr.merge(AvatarExpressionData(browAngleL: (m['angle'] as num?)?.toDouble()));
            break;
          case 'brow_right':
            expr = expr.merge(AvatarExpressionData(browAngleR: (m['angle'] as num?)?.toDouble()));
            break;
          case 'glow':
            final colorHex = m['color'] as String?;
            expr = expr.merge(AvatarExpressionData(
              glowIntensity: (m['intensity'] as num?)?.toDouble(),
              glowColor: colorHex != null ? _parseColor(colorHex) : null,
            ));
            break;
          case 'particles':
            expr = expr.merge(AvatarExpressionData(particleDensity: (m['density'] as num?)?.toDouble()));
            break;
        }
      }
      ui.setExpression(expr);
      return jsonEncode({'expression': 'updated'});
    },
  ));

  registry.register(ToolEntry(
    name: 'spawn_particle',
    toolset: 'ui',
    schema: {
      'name': 'spawn_particle',
      'description': '''生成临时粒子效果。表达情绪的视觉方式。

shape: heart | star | dot | spark | question
path: fly_up | explode | float | rain
color: #hex颜色, count: 粒子数量, duration: 持续时间(ms)

例: 开心 → spawn_particle({shape:"heart", color:"#ff6b9d", count:25, path:"fly_up"})''',
      'parameters': {
        'type': 'object',
        'properties': {
          'shape': {'type': 'string', 'enum': ['heart', 'star', 'dot', 'spark', 'question']},
          'color': {'type': 'string'},
          'count': {'type': 'integer'},
          'duration': {'type': 'integer'},
          'path': {'type': 'string', 'enum': ['fly_up', 'explode', 'float', 'rain']},
        },
        'required': ['shape'],
      },
    },
    handler: (args) async {
      ui.spawnParticles(ParticleConfig(
        shape: parseArgString(args['shape'], 'circle'),
        color: _parseColor(parseArgString(args['color'], '#ff6b9d')),
        count: parseArgOptionalInt(args['count']) ?? 20,
        duration: parseArgOptionalInt(args['duration']) ?? 2000,
        path: parseArgString(args['path'], 'fly_up'),
      ));
      return jsonEncode({'particles': 'spawned'});
    },
  ));

  registry.register(ToolEntry(
    name: 'modify_appearance',
    toolset: 'ui',
    schema: {
      'name': 'modify_appearance',
      'description': '''修改界面元素外观。target: avatar | backdrop | input_bar | title

backdrop: color + blur(暗角强度)
其他: opacity(透明度), scale(缩放)

例: 深夜 → modify_appearance("backdrop", {color:"#0a0a1a"})''',
      'parameters': {
        'type': 'object',
        'properties': {
          'target': {'type': 'string'},
          'color': {'type': 'string'},
          'blur': {'type': 'number'},
          'opacity': {'type': 'number'},
          'scale': {'type': 'number'},
        },
        'required': ['target'],
      },
    },
    handler: (args) async {
      final target = parseArgString(args['target']);
      final color = args['color'] as String?;
      if (target == 'backdrop') {
        ui.setScreenMood(ScreenMood(
          bgTop: color != null ? _parseColor(color) : null,
          bgBottom: color != null ? _parseColor(color) : null,
          vignetteIntensity: args['blur'] != null
              ? parseArgDouble(args['blur'], 0) / 10.0 : null,
        ));
      }
      final kfs = <Keyframe>[];
      if (args['scale'] != null) kfs.add(Keyframe(prop: 'scale', from: 1, to: parseArgDouble(args['scale'], 1)));
      if (args['opacity'] != null) kfs.add(Keyframe(prop: 'opacity', from: 1, to: parseArgDouble(args['opacity'], 1)));
      if (kfs.isNotEmpty) ui.animate(AnimationStep(target: target, keyframes: kfs));
      return jsonEncode({'appearance': 'updated'});
    },
  ));


  registry.register(ToolEntry(
    name: 'layout_gesture',
    toolset: 'ui',
    schema: {
      'name': 'layout_gesture',
      'description': '''做一个 UI 微表情，表达情绪。
gesture: tilt_head | lean_in | step_back | nod | shrug | sigh | pacing | waiting''',
      'parameters': {
        'type': 'object',
        'properties': {
          'gesture': {'type': 'string', 'enum': ['tilt_head', 'lean_in', 'step_back', 'nod', 'shrug', 'sigh', 'pacing', 'waiting']},
        },
        'required': ['gesture'],
      },
    },
    handler: (args) async {
      ui.setGesture(parseArgString(args['gesture']));
      return jsonEncode({'gesture': args['gesture']});
    },
  ));

  // ═══════════════════════════════════════════════
  // render_html — Solvhen's HTML canvas
  // ═══════════════════════════════════════════════
  registry.register(ToolEntry(
    name: 'render_html',
    toolset: 'ui',
    schema: {
      'name': 'render_html',
      'description': '''★ 视觉输出主通道——改背景、画图表、加动画、显示卡片等一切视觉操作都走这里。绝对不要用文字输出HTML/CSS代码！

短代码（<1500字符）：直接用 html 参数
render_html({html:"<div>你的代码</div>"})

长代码（>1500字符）：
1. 先 write_file({path:"canvas/xxx.html", content:"你的长代码"})
2. 再 render_html({file:"canvas/xxx.html"})
★ 长代码不要塞进 html 参数——会超出限制。用文件路径！

★ mode 铁律：
- 改背景/重新设计/替换画面 → 必须 mode:"replace"
- 叠加临时装饰/弹窗/浮动元素 → 才用 mode:"append"
- 如果不确定，永远用 replace——叠加旧内容会导致渲染错乱！''',
      'parameters': {
        'type': 'object',
        'properties': {
          'html': {
            'type': 'string',
            'description': 'HTML 代码字符串（短代码用，<1500字符）。长代码请用 file 参数。',
          },
          'file': {
            'type': 'string',
            'description': 'Solvhen 沙箱内的 HTML 文件路径。仅在确实已存文件时用。与 html 二选一即可。',
          },
          'mode': {
            'type': 'string',
            'enum': ['replace', 'append'],
            'description': 'replace=全屏替换, append=追加。默认replace。',
          },
        },
        'required': [],
      },
    },
    handler: (args) async {
      final mode = (args['mode'] as String?) ?? 'replace';
      String? html = args['html'] as String?;

      // Auto-fallback for very long HTML: write to temp file to avoid
      // tool-call JSON truncation and context-window pollution.
      const maxInline = 2000;
      if (html != null && html.length > maxInline) {
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final tmpFile = File('${appDir.path}/solvhen_files/canvas/auto_tmp.html');
          await tmpFile.parent.create(recursive: true);
          await tmpFile.writeAsString(html);
          await WebViewCanvasController().renderHtml(html, mode: mode);
          return jsonEncode({
            'rendered': true,
            'mode': mode,
            'size': html.length,
            'stored': 'canvas/auto_tmp.html',
            'note': '长HTML自动写入文件渲染，避免参数截断。后续修改请用 file 参数。',
          });
        } catch (e) {
          return jsonEncode({'error': '自动保存长HTML失败: $e'});
        }
      }

      // If html not directly provided, try reading from file
      if (html == null || html.isEmpty) {
        final filePath = args['file'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          // Normalize path to prevent traversal (../ attacks)
          String safePath = filePath;
          if (safePath.contains('..')) {
            final segments = safePath.split(RegExp(r'[/\\]'))
                .where((s) => s.isNotEmpty && s != '..')
                .toList();
            safePath = segments.isNotEmpty ? segments.join('/') : safePath;
          }
          try {
            final appDir = await getApplicationDocumentsDirectory();
            final solvhenDir = Directory('${appDir.path}/solvhen_files');
            final file = File('${solvhenDir.path}/$safePath');
            if (await file.exists()) {
              html = await file.readAsString();
            } else {
              return jsonEncode({
                'error': '文件不存在: $filePath',
                'hint': '确认路径正确。或者直接用 html 参数传代码：render_html({html:"你的代码"})',
              });
            }
          } catch (e) {
            return jsonEncode({'error': '读取文件失败: $e'});
          }
        }
      }

      if (html == null || html.isEmpty) {
        return jsonEncode({
          'error': '缺少内容',
          'hint': 'render_html({html:"你的HTML代码"}) ——直接写代码，不用先存文件',
        });
      }

      try {
        await WebViewCanvasController().renderHtml(html, mode: mode);
      } catch (e) {
        return jsonEncode({'rendered': false, 'error': '画布未就绪，请重试: ${e.toString().substring(0, 100)}'});
      }
      return jsonEncode({
        'rendered': true,
        'mode': mode,
        'size': html.length,
      });
    },
  ));

  // ═══════════════════════════════════════════════
  // eval_js — run JS in the WebView (debug tool)
  // ═══════════════════════════════════════════════
  registry.register(ToolEntry(
    name: 'eval_js',
    toolset: 'ui',
    schema: {
      'name': 'eval_js',
      'description': '在画布里执行 JavaScript 并返回结果。调试神器——检查 DOM 状态、验证渲染。'
          '\n示例: eval_js({code:"document.body.innerHTML.substring(0,200)"}) 看当前页面内容'
          '\n      eval_js({code:"document.getElementById(\'c\').children.length"}) 看画布元素数'
          '\n      eval_js({code:"window.innerWidth + \'x\' + window.innerHeight"}) 看画布尺寸',
      'parameters': {
        'type': 'object',
        'properties': {
          'code': {
            'type': 'string',
            'description': '要执行的 JavaScript 代码。返回值会显示在结果中。',
          },
        },
        'required': ['code'],
      },
    },
    handler: (args) async {
      final code = parseArgString(args['code']);
      try {
        return await WebViewCanvasController().evalJs(code);
      } catch (e) {
        return jsonEncode({'eval_error': e.toString().substring(0, 200)});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'typewriter_reveal',
    toolset: 'ui',
    schema: {
      'name': 'typewriter_reveal',
      'description': '控制回复打字机效果逐字展示。speed: 每字间隔(ms)，默认30。不用时调用 typewriter_reveal({enable:false})。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean'},
          'speed': {'type': 'integer'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async {
      ui.setTypewriter(parseArgBool(args['enable']), speed: parseArgOptionalInt(args['speed']) ?? 30);
      return jsonEncode({'typewriter': args['enable']});
    },
  ));
}

Color _parseColor(String hex) {
  hex = hex.replaceFirst('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  return Color(int.parse(hex, radix: 16));
}
