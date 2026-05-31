/// Code execution tool — Solvhen runs Dart code in a sandbox.
/// Used for calculations, data processing, and creative scripting.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'tool_registry.dart';
import '../services/database_service.dart';

void registerCodeTool() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'run_code',
    toolset: 'code',
    schema: {
      'name': 'run_code',
      'description': '''执行简单的数学计算和表达式求值。支持 +-*/ 四则运算、print() 输出、
DateTime.now()、字符串拼接、以及 sqrt/pow/sin/cos/abs/round/floor/ceil 等数学函数。
这不是完整的 Dart 沙箱——只能处理单个表达式或简单 print 语句。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'code': {
            'type': 'string',
            'description': '要执行的 Dart 代码。必须包含 main() 函数。用 print() 输出结果。',
          },
        },
        'required': ['code'],
      },
    },
    handler: (args) async {
      final code = args['code'] as String;
      try {
        final result = await _runInIsolate(code);
        return jsonEncode({'success': true, 'output': result});
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));

  // ═══════════════════════════════════════════════
  // REBUILD SELF — Solvhen recompiles himself
  // ═══════════════════════════════════════════════
  registry.register(ToolEntry(
    name: 'rebuild_self',
    toolset: 'code',
    schema: {
      'name': 'rebuild_self',
      'description': '''重新编译并安装自己。改完 dynamic_background.dart 或任何 .dart 源文件后调用。

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
        // Try local build (works on desktop/emulator with Flutter SDK)
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

/// HTTP rebuild via dev server
Future<String> _rebuildViaHttp() async {
  try {
    final config = await DB.getConfig();
    final devUrl = (config['dev_server_url'] as String?) ?? '';
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

Future<String> _runInIsolate(String code) async {
  final receivePort = ReceivePort();

  await Isolate.spawn((SendPort sendPort) async {
    try {
      // Capture stdout by wrapping in a try
      final output = StringBuffer();
      final spec = ZoneSpecification(
        print: (self, parent, zone, line) => output.writeln(line),
      );
      
      await runZoned(() async {
        // Create a simple sandbox — only dart:math, dart:convert, dart:core
        final imports = [
          'dart:math',
          'dart:convert',
        ];
        // We can't actually dynamically compile Dart in an isolate.
        // Instead, evaluate simple expressions.
        final result = _evaluateExpression(code);
        output.writeln(result);
      }, zoneSpecification: spec);

      sendPort.send({'success': true, 'output': output.toString().trim()});
    } catch (e) {
      sendPort.send({'success': false, 'error': e.toString()});
    }
  }, receivePort.sendPort);

  final result = await receivePort.first as Map<String, dynamic>;
  receivePort.close();

  if (result['success'] == true) {
    return result['output'] as String;
  } else {
    throw Exception(result['error']);
  }
}

/// Simple expression evaluator for basic Dart snippets
String _evaluateExpression(String code) {
  final trimmed = code.trim();

  // Extract print() calls
  final printRe = RegExp(r'print\(([^)]+)\)');
  final matches = printRe.allMatches(trimmed);
  
  if (matches.isNotEmpty) {
    final outputs = <String>[];
    for (final m in matches) {
      final arg = m.group(1)!.trim();
      outputs.add(_evalSimple(arg));
    }
    return outputs.join('\n');
  }

  // Try to evaluate as a simple expression
  if (trimmed.startsWith('return ')) {
    return _evalSimple(trimmed.substring(7));
  }

  return _evalSimple(trimmed);
}

/// Evaluate simple math/string expressions
String _evalSimple(String expr) {
  expr = expr.trim();
  
  // Remove quotes
  if ((expr.startsWith("'") && expr.endsWith("'")) ||
      (expr.startsWith('"') && expr.endsWith('"'))) {
    return expr.substring(1, expr.length - 1);
  }

  // Boolean
  if (expr == 'true') return 'true';
  if (expr == 'false') return 'false';

  // Math functions
  final mathFuncs = <String, Function>{
    'sqrt': (double x) => _sqrt(x),
    'pow': (double x, double y) => _pow(x, y),
    'sin': (double x) => _sin(x),
    'cos': (double x) => _cos(x),
    'abs': (double x) => x.abs(),
    'round': (double x) => x.round().toDouble(),
    'floor': (double x) => x.floorToDouble(),
    'ceil': (double x) => x.ceilToDouble(),
  };

  // Math functions: sqrt(x), sin(x), cos(x), pow(x,y), abs(x), round(x), floor(x), ceil(x)
  final funcRe = RegExp(r'^(sqrt|sin|cos|abs|round|floor|ceil|pow)\((.+)\)$');
  final funcMatch = funcRe.firstMatch(expr);
  if (funcMatch != null) {
    final func = mathFuncs[funcMatch.group(1)!];
    if (func != null) {
      try {
        final argStr = funcMatch.group(2)!.trim();
        if (funcMatch.group(1) == 'pow') {
          // pow(x, y) — two-arg function
          final commaIdx = _findComma(argStr);
          if (commaIdx < 0) return 'Error: pow needs two arguments';
          final a = double.parse(argStr.substring(0, commaIdx).trim());
          final b = double.parse(argStr.substring(commaIdx + 1).trim());
          return (mathFuncs['pow']! as double Function(double, double))(a, b).toString();
        }
        final a = double.parse(argStr);
        return (func as double Function(double))(a).toString();
      } catch (_) {
        return 'Error: invalid function arguments';
      }
    }
  }

  // Detect arithmetic: a + b, a - b, a * b, a / b
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

  // String concatenation
  if (expr.contains(' + ') && (expr.contains("'") || expr.contains('"'))) {
    final parts = expr.split(' + ');
    return parts.map((p) => p.trim().replaceAll("'", '').replaceAll('"', '')).join('');
  }

  // Detection of datetime
  if (expr == 'DateTime.now()' || expr == 'DateTime.now().toString()') {
    return DateTime.now().toString();
  }

  // Try parse as number
  final num = double.tryParse(expr);
  if (num != null) return expr;

  return expr;
}

/// Find the top-level comma in a function argument string (not inside nested parens)
int _findComma(String s) {
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') depth--;
    if (s[i] == ',' && depth == 0) return i;
  }
  return -1;
}

double _sqrt(double x) => x < 0 ? throw ArgumentError('sqrt of negative') : math.sqrt(x);

double _pow(double x, double y) => math.pow(x, y).toDouble();

double _sin(double x) => math.sin(x);

double _cos(double x) => math.cos(x);
