/// Solvhen AI手机智能体 — UI操作工具集
/// 提供动画、表情、粒子、外观修改、HTML渲染、JS执行等界面控制能力。
/// 工具通过 UIController 和 WebViewCanvasController 驱动 Flutter UI。
library;

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tool_registry.dart';
import 'tool_utils.dart';
import '../screens/ui_controller.dart';
import '../screens/webview_canvas.dart';
import 'package:flutter/material.dart';

/// 注册UI操作工具集
/// 工具：screen_mood(屏幕情绪)/bg_effects(背景效果)/render_html(WebView画布)/
///       particles(粒子密度)/get_mood(当前UI状态)
/// ⚠️ bg_effects不是预设枚举——AI用particles/poly/grid/pulse_ring/scanlines
/// 五条绘制原语自由组合，Canvas套壳架构：Base层→Canvas层→UI层
void registerUITools() {
  final registry = ToolRegistry();
  final ui = UIController();

  // ═══════════════════════════════════════════════════════════
  // animate — 关键帧动画序列
  // 支持多个 UI 目标元素的 scale/rotate/translate/opacity/blur 动画
  // ═══════════════════════════════════════════════════════════
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
      // 解析关键帧数组，使用安全类型转换避免 LLM 传入非预期类型导致崩溃
      final kfs = parseArgList(args['keyframes']).map((k) {
        final m = k as Map<String, dynamic>;
        return Keyframe(
          prop: parseArgString(m['prop']),
          from: parseArgDouble(m['from'], 0),
          to: parseArgDouble(m['to'], 1),
          duration: parseArgOptionalInt(m['duration']) ?? 300,
          curve: parseArgString(m['curve']), // 使用 parseArgString 而非 as String? 防止类型错误
        );
      }).toList();
      ui.animate(AnimationStep(target: target, keyframes: kfs));
      return jsonEncode({'animated': true, 'target': target, 'steps': kfs.length});
    },
  ));

  // ═══════════════════════════════════════════════════════════
  // draw_expression — 在头像画布上绘制表情
  // 通过操作序列控制眼睛、嘴巴、眉毛、光晕等元素
  // ═══════════════════════════════════════════════════════════
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
      // 从空白表情开始，逐个命令叠加——每个 merge 只覆盖非 null 字段
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
              // 注意：_parseColor 与 tools_theme.dart 中的同名函数逻辑相同
              // 后续应提取到 tool_utils.dart 中统一管理，消除重复
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

  // ═══════════════════════════════════════════════════════════
  // spawn_particle — 临时粒子效果
  // 表达情绪的视觉方式：爱心、星星、火花等
  // ═══════════════════════════════════════════════════════════
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

  // ═══════════════════════════════════════════════════════════
  // modify_appearance — 修改界面元素外观
  // 支持 backdrop（背景色+暗角）、avatar/input_bar/title（透明度+缩放）
  // ═══════════════════════════════════════════════════════════
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
      // backdrop 特殊处理：颜色应用到背景，blur 参数控制暗角强度（除以10归一化到0~1）
      if (target == 'backdrop') {
        ui.setScreenMood(ScreenMood(
          bgTop: color != null ? _parseColor(color) : null,
          bgBottom: color != null ? _parseColor(color) : null,
          vignetteIntensity: args['blur'] != null
              ? parseArgDouble(args['blur'], 0) / 10.0 : null,
        ));
      }
      // 透明度/缩放通过动画实现，使用默认 from=1 做平滑过渡
      final kfs = <Keyframe>[];
      if (args['scale'] != null) kfs.add(Keyframe(prop: 'scale', from: 1, to: parseArgDouble(args['scale'], 1)));
      if (args['opacity'] != null) kfs.add(Keyframe(prop: 'opacity', from: 1, to: parseArgDouble(args['opacity'], 1)));
      if (kfs.isNotEmpty) ui.animate(AnimationStep(target: target, keyframes: kfs));
      return jsonEncode({'appearance': 'updated'});
    },
  ));

  // ═══════════════════════════════════════════════════════════
  // layout_gesture — UI 微表情/体态动作
  // 通过预设的动画序列表达情绪（歪头、靠近、后退等）
  // ═══════════════════════════════════════════════════════════
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
  // render_html — Solvhen's HTML canvas（视觉输出主通道）
  // 所有背景、图表、动画、卡片等视觉操作都走这里
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

      // 长HTML自动写入临时文件，避免工具调用JSON截断和上下文污染
      // 注意：这里先写文件再渲染，如果渲染失败文件会残留，但下次会被覆盖
      const maxInline = 2000;
      if (html != null && html.length > maxInline) {
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final canvasDir = '${appDir.path}/solvhen_files/canvas';
          final tmpFile = File('$canvasDir/auto_tmp.html');
          await tmpFile.parent.create(recursive: true);
          await tmpFile.writeAsString(html);
          // 使用 WebViewCanvasController 单例渲染（注意：每次调用创建新实例，
          // 如果 Controller 内部持有资源未释放可能导致泄漏——后续应改为单例模式）
          await WebViewCanvasController().renderHtml(html, mode: mode);
          return jsonEncode({
            'rendered': true,
            'mode': mode,
            'size': html.length,
            'stored': 'canvas/auto_tmp.html',
            'note': '长HTML自动写入文件并渲染，避免参数截断。后续修改请用 file 参数。',
          });
        } catch (e) {
          return jsonEncode({'error': '自动保存长HTML失败: $e'});
        }
      }

      // 如果未直接提供 html，尝试从文件读取
      if (html == null || html.isEmpty) {
        final filePath = args['file'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          // 路径规范化：过滤 .. 防止目录遍历攻击
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

      // 既没有 html 也没有有效 file 路径
      if (html == null || html.isEmpty) {
        return jsonEncode({
          'error': '缺少内容',
          'hint': 'render_html({html:"你的HTML代码"}) ——直接写代码，不用先存文件',
        });
      }

      try {
        await WebViewCanvasController().renderHtml(html, mode: mode);
      } catch (e) {
        // 截断错误消息防止返回过长
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
  // eval_js — 在 WebView 中执行 JavaScript（调试工具）
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

  // ═══════════════════════════════════════════════
  // typewriter_reveal — 控制回复打字机效果
  // ═══════════════════════════════════════════════
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

  // ═══════════════════════════════════════════════
  // clear_canvas — 清空 WebView 画布
  // ═══════════════════════════════════════════════
  registry.register(ToolEntry(
    name: 'clear_canvas',
    toolset: 'ui',
    schema: {
      'name': 'clear_canvas',
      'description': '清空WebView画布，恢复透明背景。用于移除之前的render_html渲染内容。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      await WebViewCanvasController().clearCanvas();
      return jsonEncode({'cleared': true});
    },
  ));
}

/// 从十六进制字符串解析 Flutter Color。
/// 支持 #RRGGBB 和 #AARRGGBB 格式，也支持不带 # 的 6位或8位 hex。
/// 注意：与 tools_theme.dart 中的 _parseColor 功能重复，后续应合并到 tool_utils.dart。
Color _parseColor(String hex) {
  hex = hex.replaceFirst('#', '');
  // 6位hex自动补全不透明alpha通道（FF），确保颜色可见
  if (hex.length == 6) hex = 'FF$hex';
  return Color(int.parse(hex, radix: 16));
}
