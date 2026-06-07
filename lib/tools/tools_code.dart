// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 代码执行工具——run_code 可调用所有系统工具（剪切板/闪光灯/打开应用等）
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'tool_registry.dart';
import '../services/database_service.dart';

/// 注册代码执行工具
/// 
/// run_code：执行 Dart 代码，内置 tool() 函数可调用所有系统工具
/// ⚠️ 代码在主线程执行，5秒超时防卡死
/// 
/// 可用函数：
///   print(x)          — 输出结果
///   tool(name, args)  — 调用任意系统工具（如 tool('get_clipboard', {})）
///   DateTime.now()    — 当前时间
///   sqrt/pow/sin/cos/abs/round/floor/ceil — 数学函数
void registerCodeTool() {
  final registry = ToolRegistry();

  // ── run_code — 执行代码，有系统权限 ──
  registry.register(ToolEntry(
    name: 'run_code',
    toolset: 'code',
    schema: {
      'name': 'run_code',
      'description': '''执行 Dart 代码。代码中可以用以下函数：

tool('工具名', {参数}) — ⭐ 调用系统工具。所有系统操作必须通过 tool() 调用，它有完整的 Android 权限！
  - 剪切板：tool('get_clipboard', {}) / tool('set_clipboard', {'text': '...'})
  - 应用：tool('list_installed_apps', {'filter': '微信'}) / tool('open_app', {'name': '微信'})
  - 闪光灯：tool('toggle_flashlight', {'enable': true/false})
  - 锁屏/亮屏：tool('lock_screen', {}) / tool('keep_screen_on', {'enable': true})
  - 设备信息：tool('get_device_info', {}) / tool('get_battery', {})
  - 音量/亮度：tool('get_volume', {}) / tool('set_volume', {'level': 50})
  - 文件：tool('read_file', {'path': '...'}) / tool('write_file', {'path': '...', 'content': '...'})
  - 网络：tool('web_search', {'query': '...'}) / tool('fetch_url', {'url': '...'})
  - 数学：tool('eval_math', {'expression': '2+3'}) 或直接用 sqrt/pow/sin/cos 等

print(x) — 输出结果。可以有多个 print()。

不支持：if/for/while/变量声明/函数定义、文件IO、网络请求。
只能用上述函数 + 四则运算 + 字符串。

示例——打开微信：
  tool('open_app', {'name': '微信'});
  print('已打开微信');

示例——读取剪切板：
  var text = tool('get_clipboard', {});
  print('剪切板内容: ' + text);''',
      'parameters': {
        'type': 'object',
        'properties': {
          'code': {
            'type': 'string',
            'description': '要执行的代码。用 tool() 调系统功能，用 print() 输出。',
          },
        },
        'required': ['code'],
      },
    },
    handler: (args) async {
      final code = args['code'] as String;
      try {
        final result = await _runWithTools(code, registry);
        return jsonEncode({'success': true, 'output': result});
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));

  // ── rebuild_self — 自编译重装 ──
  registry.register(ToolEntry(
    name: 'rebuild_self',
    toolset: 'code',
    schema: {
      'name': 'rebuild_self',
      'description': '''重新编译并安装自己。改完 .dart 源文件后调用。

本地模式（桌面/模拟器）：直接运行 flutter build + adb install（~12秒）。
远程模式（真机）：通过 dev_server_url 触发开发机编译安装。

不需要参数。''',
      'parameters': {
        'type': 'object',
        'properties': {},
        'required': [],
      },
    },
    handler: (args) async {
      try {
        final flutterResult = await Process.run(
          'flutter', ['build', 'apk', '--debug'],
          runInShell: true,
        );
        if (flutterResult.exitCode != 0) {
          return await _rebuildViaHttp();
        }
        final apkPath = 'build/app/outputs/flutter-apk/app-debug.apk';
        final installResult = await Process.run(
          'adb', ['install', '-r', apkPath],
          runInShell: true,
        );
        if (installResult.exitCode == 0) {
          return jsonEncode({
            'rebuilt': true,
            'message': '编译安装成功。重启App即可看到新效果。',
          });
        }
        return jsonEncode({
          'rebuilt': false,
          'error': '安装失败: ${installResult.stderr}',
          'hint': '可以手动安装: adb install -r $apkPath',
        });
      } catch (e) {
        return await _rebuildViaHttp();
      }
    },
  ));
}

// ═══════════════════════════════════════════════════════════════
// 动态工具注册 — AI可以运行时给自己加新工具
// ═══════════════════════════════════════════════════════════════

/// AI动态注册的工具的handler代码存储
final _dynamicHandlers = <String, String>{};

/// 注册动态工具管理工具——AI可以运行时给自己增加/删除工具
void registerDynamicTools() {
  final registry = ToolRegistry();

  // ── register_tool — 注册一个新工具 ──
  registry.register(ToolEntry(
    name: 'register_tool',
    toolset: 'code',
    schema: {
      'name': 'register_tool',
      'description': '''注册一个新的运行时工具。注册后立即可用。

这是你扩展自己工具集的终极方式。当你发现：
- 现有工具组合不够用，需要一个专门的新工具
- 某个操作需要多步工具调用，封装成一个工具更高效
- 想给自己加一个快捷工具

handler_code 是你写的脚本代码，被调用时执行。参数通过变量注入：
  如果工具定义 parameters: {name: string, count: number}
  则 handler_code 中可直接用 var name 和 var count 获取参数值

示例——注册一个"发消息"工具：
  name: send_message
  description: 发送消息到指定应用
  parameters: {"type":"object","properties":{"app":{"type":"string"},"text":{"type":"string"}},"required":["app","text"]}
  handler_code: |
    tool('open_app', {'name': app});
    tool('set_clipboard', {'text': text});
    print('已打开' + app + '，消息已复制到剪切板');''',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '工具名（英文，如 send_message、photo_tool）',
          },
          'description': {
            'type': 'string',
            'description': '工具功能描述，给模型看的',
          },
          'parameters': {
            'type': 'object',
            'description': 'OpenAI function calling 格式的参数schema，如 {"type":"object","properties":{"x":{"type":"string"}},"required":["x"]}',
          },
          'handler_code': {
            'type': 'string',
            'description': '工具被调用时执行的代码。用 tool("工具名", {参数}) 调系统工具。参数通过变量传入。',
          },
        },
        'required': ['name', 'description', 'parameters', 'handler_code'],
      },
    },
    handler: (args) async {
      try {
        final name = args['name'] as String;
        final desc = args['description'] as String;
        final params = args['parameters'] as Map<String, dynamic>;
        final handlerCode = args['handler_code'] as String;

        // 存储handler代码
        _dynamicHandlers[name] = handlerCode;

        // 注册到ToolRegistry
        registry.register(ToolEntry(
          name: name,
          toolset: 'dynamic',
          schema: {
            'name': name,
            'description': desc,
            'parameters': params,
          },
          handler: (callArgs) => _dynamicToolHandler(callArgs, handlerCode),
        ));

        // 同时保存到DB技能表作为备份
        try {
          await DB.addSkill(
            'tool_$name',
            '动态工具: $name\n$desc\n\nHandler:\n$handlerCode',
            priority: 60,
          );
        } catch (_) {}

        return jsonEncode({
          'registered': true,
          'name': name,
          'message': '工具「$name」已注册，立即可用。重启后需重新注册（或从技能恢复）。',
        });
      } catch (e) {
        return jsonEncode({'error': '注册工具失败: $e'});
      }
    },
  ));

  // ── unregister_tool — 移除一个动态注册的工具 ──
  registry.register(ToolEntry(
    name: 'unregister_tool',
    toolset: 'code',
    schema: {
      'name': 'unregister_tool',
      'description': '移除之前用 register_tool 注册的动态工具。不能移除系统内置工具。',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '要移除的工具名'},
        },
        'required': ['name'],
      },
    },
    handler: (args) async {
      final name = args['name'] as String;
      // 不允许移除系统核心工具
      const coreTools = {
        'run_code', 'register_tool', 'unregister_tool', 'list_my_tools',
        'rebuild_self', 'add_capability',
      };
      if (coreTools.contains(name)) {
        return jsonEncode({'error': '不能移除核心工具: $name'});
      }
      _dynamicHandlers.remove(name);
      final removed = registry.unregister(name);
      return jsonEncode({
        'removed': removed,
        'name': name,
        'message': removed ? '工具「$name」已移除' : '工具「$name」不存在',
      });
    },
  ));

  // ── list_my_tools — 列出所有动态注册的工具 ──
  registry.register(ToolEntry(
    name: 'list_my_tools',
    toolset: 'code',
    schema: {
      'name': 'list_my_tools',
      'description': '列出你用 register_tool 注册的所有动态工具。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      if (_dynamicHandlers.isEmpty) {
        return jsonEncode({'tools': {}, 'message': '没有动态注册的工具'});
      }
      final tools = <String, Map<String, dynamic>>{};
      for (final e in _dynamicHandlers.entries) {
        final entry = registry[e.key];
        tools[e.key] = {
          'description': entry?.schema['description'] ?? '',
          'handler_lines': e.value.split('\n').length,
        };
      }
      return jsonEncode({'tools': tools, 'count': tools.length});
    },
  ));
}

/// 动态工具的handler——执行AI存储的代码
/// 把调用参数注入为变量，然后执行handler中的代码
Future<String> _dynamicToolHandler(Map<String, dynamic> args, String handlerCode) async {
  final buf = StringBuffer();
  for (final e in args.entries) {
    final val = e.value;
    if (val is String) {
      buf.writeln("var ${e.key} = '$val';");
    } else if (val is num || val is bool) {
      buf.writeln("var ${e.key} = $val;");
    } else {
      buf.writeln("var ${e.key} = '$val';");
    }
  }
  buf.write(handlerCode);
  return _runWithTools(buf.toString(), ToolRegistry());
}

// ═══════════════════════════════════════════════════════════════
// 核心：带 tool() 注入的代码执行
// ═══════════════════════════════════════════════════════════════

/// 在主线程执行代码，注入 tool() 函数让脚本可以调用所有系统工具。
/// 5秒超时保护，超时抛异常。
Future<String> _runWithTools(String code, ToolRegistry registry) async {
  final output = StringBuffer();
  final stopwatch = Stopwatch()..start();

  // ═══ tool() 函数 — 脚本通过它调用系统工具 ═══
  Future<String> toolFn(String name, Map<String, dynamic> args) async {
    if (stopwatch.elapsedMilliseconds > 5000) {
      throw TimeoutException('代码执行超时(5秒)');
    }
    try {
      final result = await registry.dispatch(name, args);
      return result;
    } catch (e) {
      return 'ERROR: ${e.toString().length > 200 ? e.toString().substring(0, 200) : e}';
    }
  }

  // ═══ 解析并执行代码行 ═══
  final lines = code.split('\n');
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (stopwatch.elapsedMilliseconds > 5000) {
      throw TimeoutException('代码执行超时(5秒)');
    }

    // —— print(...) ——
    final printMatch = RegExp(r"^print\('([^']*)'\);?\s*$").firstMatch(line);
    if (printMatch != null) {
      output.writeln(printMatch.group(1)!);
      continue;
    }
    final printMatch2 = RegExp(r'^print\("([^"]*)"\);?\s*$').firstMatch(line);
    if (printMatch2 != null) {
      output.writeln(printMatch2.group(1)!);
      continue;
    }

    // —— var x = tool('name', {...}) ——
    final varToolMatch = RegExp(
      r"^(?:var\s+|final\s+|String\s+|dynamic\s+)?(\w+)\s*=\s*tool\('([^']+)'\s*,\s*(\{[^}]*\})\);?\s*$"
    ).firstMatch(line);
    if (varToolMatch != null) {
      final toolName = varToolMatch.group(2)!;
      final argsStr = varToolMatch.group(3)!;
      Map<String, dynamic> toolArgs;
      try {
        // 简单JSON解析 — 支持 {key: value, key2: 'value2'} 格式
        toolArgs = _parseSimpleJson(argsStr);
      } catch (_) {
        toolArgs = {};
      }
      final result = await toolFn(toolName, toolArgs);
      // 解析tool返回的JSON，提取实际值
      String value;
      try {
        final parsed = jsonDecode(result);
        if (parsed is Map && parsed.containsKey('value')) {
          value = parsed['value'].toString();
        } else if (parsed is Map && parsed.containsKey('output')) {
          value = parsed['output'].toString();
        } else if (parsed is Map && parsed.containsKey('content')) {
          value = parsed['content'].toString();
        } else {
          value = result;
        }
      } catch (_) {
        value = result;
      }
      output.writeln(value);
      continue;
    }

    // —— tool('name', {...}) 直接调用（无赋值） ——
    final toolMatch = RegExp(
      r"^tool\('([^']+)'\s*,\s*(\{[^}]*\})\);?\s*$"
    ).firstMatch(line);
    if (toolMatch != null) {
      final toolName = toolMatch.group(1)!;
      final argsStr = toolMatch.group(2)!;
      Map<String, dynamic> toolArgs;
      try {
        toolArgs = _parseSimpleJson(argsStr);
      } catch (_) {
        toolArgs = {};
      }
      final result = await toolFn(toolName, toolArgs);
      // 输出有意义的结果
      try {
        final parsed = jsonDecode(result);
        if (parsed is Map) {
          output.writeln(parsed['value']?.toString() ?? parsed['output']?.toString() ?? parsed['message']?.toString() ?? 'ok');
        } else {
          output.writeln(result.length > 200 ? '${result.substring(0, 200)}...' : result);
        }
      } catch (_) {
        output.writeln(result.length > 200 ? '${result.substring(0, 200)}...' : result);
      }
      continue;
    }

    // —— 纯表达式求值 ——
    if (RegExp(r'^[\d\s+\-*/().\w]+$').hasMatch(line) || line.contains('DateTime.now()')) {
      try {
        final val = _evalExpression(line);
        output.writeln(val);
      } catch (e) {
        output.writeln('ERROR: $e');
      }
      continue;
    }

    // 无法识别的行 → 尝试作为表达式求值
    try {
      final val = _evalExpression(line);
      output.writeln(val);
    } catch (_) {
      output.writeln('SKIP: $line (不支持此语法)');
    }
  }

  return output.toString().trim();
}

/// 简单 JSON 解析 — 处理 {key: value, key2: 'value2'} 格式
Map<String, dynamic> _parseSimpleJson(String s) {
  final map = <String, dynamic>{};
  // 去掉首尾大括号
  var inner = s.trim();
  if (inner.startsWith('{')) inner = inner.substring(1);
  if (inner.endsWith('}')) inner = inner.substring(0, inner.length - 1);
  if (inner.trim().isEmpty) return map;

  // 简单分割（不支持嵌套）
  final parts = inner.split(',');
  for (final part in parts) {
    final colonIdx = part.indexOf(':');
    if (colonIdx < 0) continue;
    final key = part.substring(0, colonIdx).trim();
    var value = part.substring(colonIdx + 1).trim();
    // 去引号
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      value = value.substring(1, value.length - 1);
    }
    // 布尔
    if (value == 'true') {
      map[key] = true;
    } else if (value == 'false') {
      map[key] = false;
    } else {
      // 尝试数字
      final num = double.tryParse(value);
      map[key] = num ?? value;
    }
  }
  return map;
}

// ═══════════════════════════════════════════════════════════════
// 远程编译
// ═══════════════════════════════════════════════════════════════

Future<String> _rebuildViaHttp() async {
  try {
    final config = await DB.getConfig();
    final devUrl = config['dev_server_url'] ?? '';
    if (devUrl.isEmpty) {
      return jsonEncode({
        'rebuilt': false,
        'message': '真机上无法直接编译。请配置 dev_server_url 指向开发机，'
            '或手动运行: flutter build apk --debug && adb install -r',
        'hint': '设置 dev_server_url = http://192.168.0.110:9120',
      });
    }
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$devUrl/rebuild'));
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({'action': 'rebuild'}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        return jsonEncode({
          'rebuilt': true,
          'message': '远程编译成功！${jsonDecode(body)['message'] ?? ''}',
        });
      }
      return jsonEncode({
        'rebuilt': false,
        'error': '编译服务返回 ${response.statusCode}: $body',
      });
    } finally {
      client.close();
    }
  } catch (e) {
    return jsonEncode({
      'rebuilt': false,
      'error': '编译服务不可达: ${e.toString().length > 100 ? e.toString().substring(0, 100) : e}',
      'hint': '确认 dev_server_url 正确且开发机上的 rebuild_server.py 在运行',
    });
  }
}

// ═══════════════════════════════════════════════════════════════
// 纯数学表达式求值（tool() 不需要时用）
// ═══════════════════════════════════════════════════════════════

String _evalExpression(String code) {
  final trimmed = code.trim();

  // 提取 print() 调用
  final printRe = RegExp(r"print\('([^']*)'\);?");
  final match = printRe.firstMatch(trimmed);
  if (match != null) return match.group(1)!;

  final printRe2 = RegExp(r'print\("([^"]*)"\);?');
  final match2 = printRe2.firstMatch(trimmed);
  if (match2 != null) return match2.group(1)!;

  if (trimmed.startsWith('return ')) {
    return _evalSimple(trimmed.substring(7));
  }

  return _evalSimple(trimmed);
}

String _evalSimple(String expr) {
  expr = expr.trim();

  if ((expr.startsWith("'") && expr.endsWith("'")) ||
      (expr.startsWith('"') && expr.endsWith('"'))) {
    return expr.substring(1, expr.length - 1);
  }

  if (expr == 'true') return 'true';
  if (expr == 'false') return 'false';

  // DateTime.now()
  if (expr == 'DateTime.now()' || expr == 'DateTime.now().toString()') {
    return DateTime.now().toString();
  }

  // 数学函数
  final funcRe = RegExp(r'^(sqrt|sin|cos|abs|round|floor|ceil|pow)\((.+?)\)$');
  final funcMatch = funcRe.firstMatch(expr);
  if (funcMatch != null) {
    final funcName = funcMatch.group(1)!;
    final argStr = funcMatch.group(2)!.trim();
    try {
      if (funcName == 'pow') {
        final ci = _findComma(argStr);
        if (ci < 0) return 'Error: pow needs two arguments';
        final a = _parseNested(argStr.substring(0, ci).trim());
        final b = _parseNested(argStr.substring(ci + 1).trim());
        if (a == null || b == null) return '计算错误';
        return math.pow(a, b).toString();
      }
      final a = _parseNested(argStr);
      if (a == null) return '计算错误';
      switch (funcName) {
        case 'sqrt': return a < 0 ? 'Error' : math.sqrt(a).toString();
        case 'sin': return math.sin(a).toString();
        case 'cos': return math.cos(a).toString();
        case 'abs': return a.abs().toString();
        case 'round': return a.round().toString();
        case 'floor': return a.floorToDouble().toString();
        case 'ceil': return a.ceilToDouble().toString();
      }
    } catch (_) {
      return 'Error: invalid function arguments';
    }
  }

  // 四则运算
  final arithRe = RegExp(r'^([\d.]+)\s*([+\-*/])\s*([\d.]+)$');
  final arithMatch = arithRe.firstMatch(expr);
  if (arithMatch != null) {
    final a = double.parse(arithMatch.group(1)!);
    final op = arithMatch.group(2)!;
    final b = double.parse(arithMatch.group(3)!);
    switch (op) {
      case '+': return (a + b).toString();
      case '-': return (a - b).toString();
      case '*': return (a * b).toString();
      case '/': return b != 0 ? (a / b).toString() : 'Error: division by zero';
    }
  }

  final num = double.tryParse(expr);
  if (num != null) return expr;

  return expr;
}

double? _parseNested(String expr) {
  expr = expr.trim();
  final num = double.tryParse(expr);
  if (num != null) return num;

  final nestedRe = RegExp(r'^(sqrt|sin|cos|abs|round|floor|ceil|pow)\((.+?)\)$');
  final m = nestedRe.firstMatch(expr);
  if (m != null) {
    final funcName = m.group(1)!;
    final argStr = m.group(2)!.trim();
    if (funcName == 'pow') {
      final ci = _findComma(argStr);
      if (ci < 0) return null;
      final a = _parseNested(argStr.substring(0, ci).trim());
      final b = _parseNested(argStr.substring(ci + 1).trim());
      if (a == null || b == null) return null;
      return math.pow(a, b).toDouble();
    }
    final a = _parseNested(argStr);
    if (a == null) return null;
    switch (funcName) {
      case 'sqrt': return a < 0 ? null : math.sqrt(a);
      case 'sin': return math.sin(a);
      case 'cos': return math.cos(a);
      case 'abs': return a.abs();
      case 'round': return a.round().toDouble();
      case 'floor': return a.floorToDouble();
      case 'ceil': return a.ceilToDouble();
    }
  }
  return null;
}

int _findComma(String s) {
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') depth--;
    if (s[i] == ',' && depth == 0) return i;
  }
  return -1;
}
