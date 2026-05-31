/// UI control tools — agent freely modifies its own interface.
/// Tools: animate, draw_expression, spawn_particle, modify_appearance,
/// screen_mood, layout_gesture, typewriter_reveal
library;

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tool_registry.dart';
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
      final target = args['target'] as String;
      final kfs = (args['keyframes'] as List<dynamic>).map((k) {
        final m = k as Map<String, dynamic>;
        return Keyframe(
          prop: m['prop'] as String,
          from: (m['from'] as num).toDouble(),
          to: (m['to'] as num).toDouble(),
          duration: (m['duration'] as int?) ?? 300,
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
      final cmds = args['commands'] as List<dynamic>;
      var expr = const AvatarExpressionData();
      for (final c in cmds) {
        final m = c as Map<String, dynamic>;
        switch (m['op'] as String) {
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
        shape: args['shape'] as String,
        color: _parseColor((args['color'] as String?) ?? '#ff6b9d'),
        count: (args['count'] as int?) ?? 20,
        duration: (args['duration'] as int?) ?? 2000,
        path: (args['path'] as String?) ?? 'fly_up',
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
      final target = args['target'] as String;
      final color = args['color'] as String?;
      if (target == 'backdrop') {
        ui.setScreenMood(ScreenMood(
          bgTop: color != null ? _parseColor(color) : null,
          bgBottom: color != null ? _parseColor(color) : null,
          vignetteIntensity: (args['blur'] as num?)?.toDouble() != null
              ? (args['blur'] as num).toDouble() / 10.0 : null,
        ));
      }
      final kfs = <Keyframe>[];
      if (args['scale'] != null) kfs.add(Keyframe(prop: 'scale', from: 1, to: (args['scale'] as num).toDouble()));
      if (args['opacity'] != null) kfs.add(Keyframe(prop: 'opacity', from: 1, to: (args['opacity'] as num).toDouble()));
      if (kfs.isNotEmpty) ui.animate(AnimationStep(target: target, keyframes: kfs));
      return jsonEncode({'appearance': 'updated'});
    },
  ));

  registry.register(ToolEntry(
    name: 'screen_mood',
    toolset: 'ui',
    schema: {
      'name': 'screen_mood',
      'description': '''修改屏幕氛围。用 bg_effects 自由绘画。

⛔ 不要调用的情况：
  - 普通聊天/问题/抱怨 → 不要动背景
  - 没提背景/风格/氛围/主题 → 不要调用
✅ 对方提到以下才可调用："背景" "风格" "主题" "氛围" "换个" "改一下" "赛博朋克" "暗黑" "樱花" "极简"

基础参数（全部可选）：color,bg_top,bg_bottom,vignette,particles(0-1),particle_speed,accent

━━━━━━━━━━━━━━━━━━━━━━━━━━
★ bg_effects — 你的画布。每项是一个绘制操作。
  不要只用一种——叠加才有层次。
━━━━━━━━━━━━━━━━━━━━━━━━━━

┌─ canvas（首选！自由形状 + 模糊 + 混合模式）─┐
│ 这是你最强大的画笔。用它画任何东西。       │
│                                            │
│ shape: circle | ellipse | rect | path       │
│ path用points: "x1,y1 x2,y2 ..." 定义多边形 │
│ x,y: 0-1位置  fill/stroke: #hex色           │
│ opacity: 0-1   rotation: 弧度               │
│ scale_x, scale_y: 缩放                      │
│ ★ blur: 高斯模糊半径(px) — 软光的关键       │
│ ★ blend: screen|overlay|softLight|plus|     │
│          multiply|lighten|colorDodge         │
│                                            │
│ 模糊 + screen混合 = 发光雾带 = 银河本河     │
│ 多个椭圆叠在不同位置 = 星云层次             │
│ path多边形 + blur = 极光带                   │
└────────────────────────────────────────────┘

┌─ particles（粒子系统，搭配canvas用）───────┐
│ shape: circle|ellipse|diamond|star5|star8|  │
│        star12|poly:x1,y1 x2,y2...           │
│ color, count(1-200), speed(0.1-5)          │
│ scale(0.1-3), sway(0-100), rotate(bool)     │
│ direction:[dx,dy]                           │
└────────────────────────────────────────────┘

┌─ grid / pulse_ring / scanlines（辅助线框）─┐
│ grid: spacing,color,opacity,perspective     │
│ pulse_ring: x,y,radius,color,opacity,speed  │
│ scanlines: direction,spacing,color,opacity  │
│ 这些是装饰，不要当主力——canvas才是画笔。   │
└────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━
示例——注意：每个场景用的是什么手法
━━━━━━━━━━━━━━━━━━━━━━━━━━

弥散光斑（最简单的canvas用法——一个大椭圆+模糊+screen）：
{screen_mood({bg_top:"#010308",bg_bottom:"#050d1f",
  bg_effects:[
    {op:"canvas",shape:"ellipse",x:0.5,y:0.45,rx:200,ry:140,
      fill:"#4466cc",opacity:0.25,blur:40,blend:"screen"}
  ]})}

银河（canvas模糊光斑叠层 + 微点粒子点缀）：
{screen_mood({bg_top:"#010308",bg_bottom:"#050d1f",vignette:0.45,
  bg_effects:[
    {op:"canvas",shape:"ellipse",x:0.5,y:0.5,rx:180,ry:140,
      fill:"#4466cc",opacity:0.18,blur:35,blend:"screen"},
    {op:"canvas",shape:"ellipse",x:0.35,y:0.45,rx:120,ry:80,
      fill:"#88aaff",opacity:0.15,blur:45,blend:"overlay"},
    {op:"canvas",shape:"ellipse",x:0.65,y:0.55,rx:100,ry:60,
      fill:"#aaccff",opacity:0.12,blur:50,blend:"screen"},
    {op:"particles",shape:"dot",color:"#ffffff",count:80,
      speed:0.03,sway:3,scale:0.2,direction:[0,0.02]}
  ]})}

极光（path多边形 + 大模糊 + screen混合）：
{screen_mood({bg_top:"#020210",bg_bottom:"#0a0a1a",
  bg_effects:[
    {op:"canvas",shape:"path",
      points:"-400,20 -200,-40 0,10 150,-30 300,15 450,-10",
      x:0.5,y:0.4,fill:"#44ff88",opacity:0.15,blur:30,blend:"screen",
      scale_x:1.5,scale_y:0.8},
    {op:"canvas",shape:"path",
      points:"-350,30 -150,-20 50,15 200,-25 400,10",
      x:0.45,y:0.45,fill:"#4488ff",opacity:0.12,blur:35,blend:"overlay",
      scale_x:1.3,scale_y:0.7}
  ]})}

多个发光球体（circle + blur + screen，不同位置不同颜色）：
{screen_mood({bg_top:"#0a0010",bg_bottom:"#100020",
  bg_effects:[
    {op:"canvas",shape:"circle",x:0.3,y:0.4,radius:80,
      fill:"#ff4488",opacity:0.2,blur:30,blend:"screen"},
    {op:"canvas",shape:"circle",x:0.6,y:0.35,radius:60,
      fill:"#44aaff",opacity:0.2,blur:25,blend:"screen"},
    {op:"canvas",shape:"circle",x:0.45,y:0.55,radius:50,
      fill:"#8844ff",opacity:0.18,blur:20,blend:"overlay"}
  ]})}''',
      'parameters': {
        'type': 'object',
        'properties': {
          'color': {'type': 'string'},
          'primary': {'type': 'string'},
          'accent': {'type': 'string'},
          'bg_top': {'type': 'string'},
          'bg_bottom': {'type': 'string'},
          'vignette': {'type': 'number'},
          'vignette_color': {'type': 'string'},
          'particles': {'type': 'number'},
          'particle_speed': {'type': 'number'},
          'bg_effects': {
            'type': 'array',
            'description': '绘制原语数组',
            'items': {
              'type': 'object',
              'properties': {
                'op': {'type': 'string', 'enum': ['particles', 'grid', 'pulse_ring', 'scanlines', 'canvas']},
                'shape': {'type': 'string'},
                'color': {'type': 'string'},
                'count': {'type': 'integer'},
                'speed': {'type': 'number'},
                'scale': {'type': 'number'},
                'sway': {'type': 'number'},
                'rotate': {'type': 'boolean'},
                'direction': {'type': 'array', 'items': {'type': 'number'}},
                'spacing': {'type': 'number'},
                'opacity': {'type': 'number'},
                'perspective': {'type': 'boolean'},
                'x': {'type': 'number'}, 'y': {'type': 'number'},
                'radius': {'type': 'number'},
                'width': {'type': 'number'},
                // canvas params
                'fill': {'type': 'string'},
                'stroke': {'type': 'string'},
                'stroke_width': {'type': 'number'},
                'blur': {'type': 'number'},
                'blend': {'type': 'string'},
                'scale_x': {'type': 'number'}, 'scale_y': {'type': 'number'},
                'rotation': {'type': 'number'},
                'points': {'type': 'string'},
              },
            },
          },
        },
        'required': [],
      },
    },
    handler: (args) async {
      final colorStr = (args['color'] as String?) ?? args['bg_top'] as String? ?? args['bg_bottom'] as String?;
      final topColor = args['bg_top'] != null ? _parseColor(args['bg_top'] as String) : null;
      final bottomColor = args['bg_bottom'] != null ? _parseColor(args['bg_bottom'] as String) : null;
      final fallbackColor = colorStr != null ? _parseColor(colorStr) : null;

      List<Map<String, dynamic>>? effects;
      final rawEffects = args['bg_effects'];
      if (rawEffects is List) {
        effects = rawEffects
            .whereType<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (effects.isEmpty) effects = null;
      }
      // If bg_effects not explicitly passed, pass empty list to clear old effects.
      // (ScreenMood.merge treats null as "keep old" — we want "clear" on omit.)
      final clearEffects = args.containsKey('bg_effects') ? effects : <Map<String, dynamic>>[];

      ui.setScreenMood(ScreenMood(
        primary: args['primary'] != null ? _parseColor(args['primary'] as String) : null,
        accent: args['accent'] != null ? _parseColor(args['accent'] as String) : null,
        bgTop: topColor ?? fallbackColor,
        bgBottom: bottomColor ?? fallbackColor,
        vignetteIntensity: (args['vignette'] as num?)?.toDouble(),
        vignetteColor: args['vignette_color'] != null ? _parseColor(args['vignette_color'] as String) : null,
        // Preserve old particle density unless explicitly changed
        particleDensity: args.containsKey('particles')
            ? (args['particles'] as num?)?.toDouble()
            : null,
        particleSpeed: (args['particle_speed'] as num?)?.toDouble(),
        bgEffects: clearEffects,
      ));
      return jsonEncode({'mood': 'updated', 'effects': effects?.length ?? 0});
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
      ui.setGesture(args['gesture'] as String);
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

mode: "replace"(全屏替换,默认) | "append"(追加)
画布透明背景，全屏宽高。在消息层下方作为背景，重启后自动恢复最后一次 replace 的内容。''',
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

      await WebViewCanvasController().renderHtml(html, mode: mode);
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
      final code = args['code'] as String;
      return await WebViewCanvasController().evalJs(code);
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
      ui.setTypewriter(args['enable'] as bool, speed: (args['speed'] as int?) ?? 30);
      return jsonEncode({'typewriter': args['enable']});
    },
  ));
}

Color _parseColor(String hex) {
  hex = hex.replaceFirst('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  return Color(int.parse(hex, radix: 16));
}
