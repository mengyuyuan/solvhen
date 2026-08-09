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
import '../core/security/developer_mode.dart';
import '../core/security/tool_security.dart';

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

  // ── run_code — 受限 DSL；每个嵌套工具仍单独通过策略引擎 ──
  registry.register(ToolEntry(
    name: 'run_code',
    toolset: 'code',
    schema: {
      'name': 'run_code',
      'description': '''执行 Dart 代码。代码中可以用以下函数：

tool('工具名', {参数}) — 调用已注册工具。每次嵌套调用都会重新经过来源、能力、风险与用户确认策略，脚本不能绕过权限。
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
    risk: ToolRisk.destructive,
    capabilities: const {'code'},
    supportedOrigins: const {ExecutionOrigin.localUser},
    handler: (args) async {
      final code = args['code'] as String;
      try {
        final result = await _runWithTools(code, registry);
        return jsonEncode({'success': true, 'output': result});
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
    contextualHandler: (args, context) async {
      final code = args['code'] as String;
      try {
        final result = await _runWithTools(code, registry, context: context);
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
      'description': '''通过已配对的局域网开发服务器重新编译并安装自己。

仅在用户显式开启开发者模式后出现；服务器地址必须是回环或私网地址，请求必须携带 Keystore 中的 256 位 token 和一次性 nonce，并且每次调用都由用户确认。

不需要参数。''',
      'parameters': {
        'type': 'object',
        'properties': {},
        'required': [],
      },
    },
    checkFn: () => DeveloperModeSession.instance.enabled,
    risk: ToolRisk.destructive,
    capabilities: const {'code'},
    supportedOrigins: const {ExecutionOrigin.localUser},
    handler: (_) => _rebuildViaHttp(),
    contextualHandler: (_, context) => _rebuildViaHttp(context: context),
  ));
}

// ═══════════════════════════════════════════════════════════════
// 动态工具注册 — AI可以运行时给自己加新工具
// ═══════════════════════════════════════════════════════════════

class _DynamicToolDefinition {
  const _DynamicToolDefinition({
    required this.code,
    required this.capabilities,
  });

  final String code;
  final Set<String> capabilities;
}

/// Dynamic tools are process-local. Their source is kept for the permission
/// preview and diagnostics; it is never compiled or evaluated as native Dart.
final _dynamicHandlers = <String, _DynamicToolDefinition>{};

const _dynamicCapabilityAllowlist = <String>{
  'file',
  'system',
  'web',
  'memory',
  'history',
  'ui',
  'model',
  'proactive',
};

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

动态工具只支持受限 DSL，不会执行原生 Dart。注册前必须声明能力；
用户会看到名称、能力和完整 handler_code，并决定是否允许。

handler_code 是你写的脚本代码，被调用时执行。参数通过变量注入：
  如果工具定义 parameters: {name: string, count: number}
  则 handler_code 中可直接用 var name 和 var count 获取参数值

示例——注册一个"发消息"工具：
  name: send_message
  description: 发送消息到指定应用
  parameters: {"type":"object","properties":{"app":{"type":"string"},"text":{"type":"string"}},"required":["app","text"]}
  capabilities: [system]
  handler_code: |
    tool('open_app', {'name': app});
    tool('set_clipboard', {'text': text});
    print('操作完成');''',
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
            'description':
                'OpenAI function calling 格式的参数schema，如 {"type":"object","properties":{"x":{"type":"string"}},"required":["x"]}',
          },
          'handler_code': {
            'type': 'string',
            'description':
                '受限 DSL。仅支持 tool(...)、接收工具结果、print(字面量)和简单数学表达式；最多 60 行。',
          },
          'capabilities': {
            'type': 'array',
            'items': {
              'type': 'string',
              'enum': _dynamicCapabilityAllowlist.toList(),
            },
            'description': '该工具允许调用的能力，必须覆盖 handler_code 中每个嵌套工具。',
          },
        },
        'required': [
          'name',
          'description',
          'parameters',
          'handler_code',
          'capabilities',
        ],
      },
    },
    risk: ToolRisk.destructive,
    capabilities: const {'code'},
    supportedOrigins: const {ExecutionOrigin.localUser},
    handler: (args) => _registerDynamicTool(args, registry),
    contextualHandler: (args, context) =>
        _registerDynamicTool(args, registry, context: context),
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
    risk: ToolRisk.destructive,
    capabilities: const {'code'},
    supportedOrigins: const {ExecutionOrigin.localUser},
    handler: (args) async {
      final name = args['name'] as String;
      // 不允许移除系统核心工具
      const coreTools = {
        'run_code',
        'register_tool',
        'unregister_tool',
        'list_my_tools',
        'rebuild_self',
        'add_capability',
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
          'handler_lines': e.value.code.split('\n').length,
          'capabilities': e.value.capabilities.toList()..sort(),
        };
      }
      return jsonEncode({'tools': tools, 'count': tools.length});
    },
  ));
}

Future<String> _registerDynamicTool(
  Map<String, dynamic> args,
  ToolRegistry registry, {
  ToolContext? context,
}) async {
  try {
    context?.cancellation.throwIfCancelled();
    final name = (args['name'] as String? ?? '').trim();
    final description = (args['description'] as String? ?? '').trim();
    final rawParameters = args['parameters'];
    final parameters = rawParameters is Map
        ? Map<String, dynamic>.from(rawParameters)
        : <String, dynamic>{};
    final code = (args['handler_code'] as String? ?? '').trim();
    final rawCapabilities = args['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities
            .map((item) => '$item'.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
        : <String>{};

    final validation = _validateDynamicTool(
      name: name,
      description: description,
      parameters: parameters,
      code: code,
      capabilities: capabilities,
      registry: registry,
    );
    if (validation != null) {
      return jsonEncode({'registered': false, 'error': validation});
    }

    final definition = _DynamicToolDefinition(
      code: code,
      capabilities: Set.unmodifiable(capabilities),
    );
    _dynamicHandlers[name] = definition;
    registry.register(ToolEntry(
      name: name,
      toolset: 'dynamic',
      schema: {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
      risk: ToolRisk.destructive,
      capabilities: {'code', ...capabilities},
      supportedOrigins: const {ExecutionOrigin.localUser},
      handler: (callArgs) => _dynamicToolHandler(callArgs, definition),
      contextualHandler: (callArgs, nestedContext) =>
          _dynamicToolHandler(callArgs, definition, context: nestedContext),
    ));

    try {
      final sortedCapabilities = capabilities.toList()..sort();
      await DB.addSkill(
        'tool_$name',
        '动态工具: $name\n$description\n'
            '能力: ${sortedCapabilities.join(', ')}\n\nHandler:\n$code',
        priority: 60,
      );
    } catch (_) {
      // The in-memory registration remains usable; DB backup is best effort.
    }

    return jsonEncode({
      'registered': true,
      'name': name,
      'capabilities': capabilities.toList()..sort(),
      'message': '工具「$name」已注册。它只在当前进程有效，且每次调用仍会经过策略与确认。',
    });
  } catch (error) {
    return jsonEncode({'registered': false, 'error': '注册工具失败: $error'});
  }
}

String? _validateDynamicTool({
  required String name,
  required String description,
  required Map<String, dynamic> parameters,
  required String code,
  required Set<String> capabilities,
  required ToolRegistry registry,
}) {
  if (!RegExp(r'^[a-z][a-z0-9_]{2,47}$').hasMatch(name)) {
    return '工具名必须是 3–48 位小写英文、数字或下划线，并以字母开头';
  }
  if (registry.contains(name)) return '工具名已存在；请先移除旧动态工具，不能覆盖内置工具';
  if (description.isEmpty || description.length > 300) {
    return '描述长度必须为 1–300 字符';
  }
  if (code.isEmpty || code.length > 4000 || code.split('\n').length > 60) {
    return 'handler_code 必须为 1–4000 字符且不超过 60 行';
  }
  if (!capabilities.every(_dynamicCapabilityAllowlist.contains)) {
    return '包含不受支持的能力声明';
  }
  if (parameters['type'] != 'object' || parameters['properties'] is! Map) {
    return 'parameters 必须是 type=object 的函数参数 schema';
  }

  final propertyNames = (parameters['properties'] as Map).keys.map((e) => '$e');
  if (propertyNames.any(
      (name) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,47}$').hasMatch(name))) {
    return '参数名格式无效';
  }

  final directTool =
      RegExp(r"^tool\('[a-z][a-z0-9_]*'\s*,\s*\{[^{}]*\}\);?\s*$");
  final assignedTool = RegExp(
    r"^(?:var\s+|final\s+|String\s+|dynamic\s+)?[A-Za-z_]\w*\s*=\s*tool\('[a-z][a-z0-9_]*'\s*,\s*\{[^{}]*\}\);?\s*$",
  );
  final printLiteral = RegExp(r'''^print\((?:'[^']*'|"[^"]*")\);?\s*$''');
  final expression = RegExp(r'^[\d\s+\-*/().]+;?\s*$');

  for (final rawLine in code.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (!directTool.hasMatch(line) &&
        !assignedTool.hasMatch(line) &&
        !printLiteral.hasMatch(line) &&
        !expression.hasMatch(line) &&
        line != 'DateTime.now();' &&
        line != 'DateTime.now()') {
      return 'DSL 不支持这一行：${line.length > 80 ? '${line.substring(0, 80)}…' : line}';
    }
  }

  for (final toolName in _extractNestedToolNames(code)) {
    final entry = registry[toolName];
    if (entry == null) return 'handler_code 引用了未知工具：$toolName';
    if (entry.toolset == 'code' ||
        entry.toolset == 'dynamic' ||
        entry.toolset == 'delegation') {
      return '动态工具不能调用代码、动态工具或子 Agent：$toolName';
    }
    final missing = entry.effectiveCapabilities.difference(capabilities);
    if (missing.isNotEmpty) {
      return '工具 $toolName 需要先声明能力：${missing.join(', ')}';
    }
  }
  return null;
}

Set<String> _extractNestedToolNames(String code) => RegExp(
      r"tool\('([a-z][a-z0-9_]*)'\s*,",
    ).allMatches(code).map((match) => match.group(1)!).toSet();

/// 动态工具的handler——执行AI存储的代码
/// 把调用参数注入为变量，然后执行handler中的代码
Future<String> _dynamicToolHandler(
  Map<String, dynamic> args,
  _DynamicToolDefinition definition, {
  ToolContext? context,
}) async {
  final dynamicContext = context?.asOrigin(
    ExecutionOrigin.dynamicTool,
    parent: 'dynamic_tool',
  );
  return _runWithTools(
    definition.code,
    ToolRegistry(),
    context: dynamicContext,
    variables: args,
    allowedCapabilities: definition.capabilities,
    forbidPrivilegedTools: true,
  );
}

// ═══════════════════════════════════════════════════════════════
// 核心：带 tool() 注入的代码执行
// ═══════════════════════════════════════════════════════════════

/// 在主线程执行代码，注入 tool() 函数让脚本可以调用所有系统工具。
/// 5秒超时保护，超时抛异常。
Future<String> _runWithTools(
  String code,
  ToolRegistry registry, {
  ToolContext? context,
  Map<String, dynamic> variables = const {},
  Set<String>? allowedCapabilities,
  bool forbidPrivilegedTools = false,
}) async {
  final output = StringBuffer();
  final stopwatch = Stopwatch()..start();

  // ═══ tool() 函数 — 脚本通过它调用系统工具 ═══
  Future<String> toolFn(String name, Map<String, dynamic> args) async {
    if (stopwatch.elapsedMilliseconds > 5000) {
      throw TimeoutException('代码执行超时(5秒)');
    }
    try {
      context?.cancellation.throwIfCancelled();
      final entry = registry[name];
      if (entry == null) return 'ERROR: unknown tool: $name';
      if (forbidPrivilegedTools &&
          (entry.toolset == 'code' ||
              entry.toolset == 'dynamic' ||
              entry.toolset == 'delegation')) {
        return 'ERROR: privileged nested tool denied: $name';
      }
      if (allowedCapabilities != null) {
        final missing =
            entry.effectiveCapabilities.difference(allowedCapabilities);
        if (missing.isNotEmpty) {
          return 'ERROR: undeclared capabilities for $name: ${missing.join(', ')}';
        }
      }
      final result = await registry.dispatch(
        name,
        args,
        context: context?.nested(name),
        onApproval: context?.approval,
      );
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
            r"^(?:var\s+|final\s+|String\s+|dynamic\s+)?(\w+)\s*=\s*tool\('([^']+)'\s*,\s*(\{[^}]*\})\);?\s*$")
        .firstMatch(line);
    if (varToolMatch != null) {
      final toolName = varToolMatch.group(2)!;
      final argsStr = varToolMatch.group(3)!;
      Map<String, dynamic> toolArgs;
      try {
        // 简单JSON解析 — 支持 {key: value, key2: 'value2'} 格式
        toolArgs = _parseSimpleJson(argsStr, variables: variables);
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
    final toolMatch =
        RegExp(r"^tool\('([^']+)'\s*,\s*(\{[^}]*\})\);?\s*$").firstMatch(line);
    if (toolMatch != null) {
      final toolName = toolMatch.group(1)!;
      final argsStr = toolMatch.group(2)!;
      Map<String, dynamic> toolArgs;
      try {
        toolArgs = _parseSimpleJson(argsStr, variables: variables);
      } catch (_) {
        toolArgs = {};
      }
      final result = await toolFn(toolName, toolArgs);
      // 输出有意义的结果
      try {
        final parsed = jsonDecode(result);
        if (parsed is Map) {
          output.writeln(parsed['value']?.toString() ??
              parsed['output']?.toString() ??
              parsed['message']?.toString() ??
              'ok');
        } else {
          output.writeln(
              result.length > 200 ? '${result.substring(0, 200)}...' : result);
        }
      } catch (_) {
        output.writeln(
            result.length > 200 ? '${result.substring(0, 200)}...' : result);
      }
      continue;
    }

    // —— 纯表达式求值 ——
    if (RegExp(r'^[\d\s+\-*/().\w]+$').hasMatch(line) ||
        line.contains('DateTime.now()')) {
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
Map<String, dynamic> _parseSimpleJson(
  String s, {
  Map<String, dynamic> variables = const {},
}) {
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
    var key = part.substring(0, colonIdx).trim();
    var value = part.substring(colonIdx + 1).trim();
    if ((key.startsWith("'") && key.endsWith("'")) ||
        (key.startsWith('"') && key.endsWith('"'))) {
      key = key.substring(1, key.length - 1);
    }
    // 去引号
    final quoted = (value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'));
    if (quoted) {
      value = value.substring(1, value.length - 1);
    }
    if (!quoted && variables.containsKey(value)) {
      map[key] = variables[value];
      continue;
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

Future<String> _rebuildViaHttp({ToolContext? context}) async {
  try {
    if (!DeveloperModeSession.instance.enabled) {
      return jsonEncode({
        'rebuilt': false,
        'error': '开发者模式未开启，rebuild_self 不可用',
      });
    }
    context?.cancellation.throwIfCancelled();
    final config = await DB.getConfig();
    final baseUrl = normalizePrivateDeveloperUrl(config['dev_server_url']);
    if (baseUrl == null) {
      return jsonEncode({
        'rebuilt': false,
        'error': '开发服务器地址无效；只允许 localhost、回环地址或私网 IP，且不能包含账号、查询参数或片段',
      });
    }
    final token = await DeveloperCredentials().readToken();
    if (token == null || token.length < 32) {
      return jsonEncode({
        'rebuilt': false,
        'error': '尚未生成 256 位开发服务器 token，请先在开发者设置中配对',
      });
    }
    context?.cancellation.throwIfCancelled();

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final cancelFuture = context?.cancellation.whenCancelled.then((_) {
      client.close(force: true);
    });
    if (cancelFuture != null) unawaited(cancelFuture);
    try {
      final endpoint = baseUrl.replace(path: '${baseUrl.path}/rebuild');
      final request = await client.postUrl(endpoint).timeout(
            const Duration(seconds: 8),
          );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('X-Solvhen-Nonce', _randomNonce());
      request.write(jsonEncode({'action': 'rebuild'}));
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(minutes: 6));
      context?.cancellation.throwIfCancelled();
      final decoded = jsonDecode(body);
      final result = decoded is Map ? decoded : const <String, dynamic>{};
      if (response.statusCode == 200 && result['rebuilt'] == true) {
        return jsonEncode({
          'rebuilt': true,
          'message': '远程编译安装成功。${result['message'] ?? ''}',
        });
      }
      return jsonEncode({
        'rebuilt': false,
        'error': '编译服务返回 ${response.statusCode}: '
            '${result['error'] ?? '请求未完成'}',
      });
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    return jsonEncode({
      'rebuilt': false,
      'error':
          '编译服务不可达: ${e.toString().length > 100 ? e.toString().substring(0, 100) : e}',
      'hint': '确认开发者模式、私网地址、Bearer token、客户端 IP 白名单和 rebuild_server.py 配置一致',
    });
  }
}

String _randomNonce() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
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
        case 'sqrt':
          return a < 0 ? 'Error' : math.sqrt(a).toString();
        case 'sin':
          return math.sin(a).toString();
        case 'cos':
          return math.cos(a).toString();
        case 'abs':
          return a.abs().toString();
        case 'round':
          return a.round().toString();
        case 'floor':
          return a.floorToDouble().toString();
        case 'ceil':
          return a.ceilToDouble().toString();
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
      case '+':
        return (a + b).toString();
      case '-':
        return (a - b).toString();
      case '*':
        return (a * b).toString();
      case '/':
        return b != 0 ? (a / b).toString() : 'Error: division by zero';
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

  final nestedRe =
      RegExp(r'^(sqrt|sin|cos|abs|round|floor|ceil|pow)\((.+?)\)$');
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
      case 'sqrt':
        return a < 0 ? null : math.sqrt(a);
      case 'sin':
        return math.sin(a);
      case 'cos':
        return math.cos(a);
      case 'abs':
        return a.abs();
      case 'round':
        return a.round().toDouble();
      case 'floor':
        return a.floorToDouble();
      case 'ceil':
        return a.ceilToDouble();
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
