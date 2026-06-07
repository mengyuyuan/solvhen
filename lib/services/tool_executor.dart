/// Tool execution engine — parallel execution, state tracking, timeout, retry.
/// V2.1: fixed result ordering bug, added web_extract to parallel set, proper timeout.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:async';
import '../tools/tool_registry.dart';
import '../screens/agent_avatar.dart' show AgentState;

class ToolCall {
  final String id;
  final String name;
  final String arguments;

  const ToolCall({required this.id, required this.name, required this.arguments});
  Map<String, dynamic> get args {
    try {
      return jsonDecode(arguments) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

typedef StateCallback = void Function(AgentState state);
typedef ToolProgressCallback = void Function(String toolName, String status);

class ToolExecutor {
  final ToolRegistry _registry;
  final int maxIterations;
  StateCallback? onStateChange;
  ToolProgressCallback? onToolProgress;

  ToolExecutor({
    ToolRegistry? registry,
    this.maxIterations = 5,
    this.onStateChange,
    this.onToolProgress,
  }) : _registry = registry ?? ToolRegistry();

  static List<ToolCall>? parseToolCalls(Map<String, dynamic>? message) {
    if (message == null) return null;
    final toolCalls = message['tool_calls'] as List<dynamic>?;
    if (toolCalls == null || toolCalls.isEmpty) return null;
    return toolCalls.map((tc) {
      final f = tc['function'] as Map<String, dynamic>;
      return ToolCall(
        id: tc['id'] as String? ?? 'call_0',
        name: f['name'] as String,
        arguments: f['arguments'] as String? ?? '{}',
      );
    }).toList();
  }

  // Compiled-once regexes — avoids recompilation on every call.
  static final _invokeRe = RegExp(r'<invoke\s+name="(\w+)"\s*>(.*?)</invoke>', dotAll: true);
  static final _dsmlInvokeRe = RegExp(r'<\s*\|*\s*DSML\s*\|*\s*invoke\s+name="(\w+)"[^>]*>(.*?)</\s*\|*\s*DSML\s*\|*\s*invoke\s*>', dotAll: true);
  static final _paramBlockRe = RegExp(r'<parameter[^>]*>(.*?)</parameter>', dotAll: true);
  static final _dsmlParamRe = RegExp(r'<\s*\|*\s*DSML\s*\|*\s*parameter[^>]*>(.*?)</\s*\|*\s*DSML\s*\|*\s*parameter\s*>', dotAll: true);
  static final _nameRe = RegExp(r'name="(\w+)"');

  /// DeepSeek sometimes returns tool calls as XML inside content text
  /// instead of in the tool_calls array. Parse them out.
  /// Supports both standard (<invoke>) and DSML (<|DSML|invoke>) formats.
  static List<ToolCall>? parseToolCallsFromContent(String content) {
    // Try standard XML first, then DSML
    var matches = _invokeRe.allMatches(content);
    var paramBlockRe = _paramBlockRe;
    if (matches.isEmpty) {
      matches = _dsmlInvokeRe.allMatches(content);
      paramBlockRe = _dsmlParamRe;
    }
    if (kDebugMode) debugPrint('[PARSE-XML] content_len=${content.length} match_count=${matches.length} first20=${content.length > 20 ? content.substring(0, 20) : content}');
    if (matches.isEmpty) return null;

    final calls = <ToolCall>[];
    var idx = 0;
    for (final m in matches) {
      final name = m.group(1)!;
      final body = m.group(2)!;
      final params = <String, dynamic>{};
      // Two-pass: extract param blocks, then parse name from opening tag
      for (final pm in _paramBlockRe.allMatches(body)) {
        final tag = pm.group(0)!; // full <parameter ...>...</parameter>
        final nameMatch = _nameRe.firstMatch(tag);
        if (nameMatch == null) continue;
        dynamic val = pm.group(1)!;
        // DeepSeek XML may embed JSON in structured params (bg_effects, keyframes, etc.).
        // Try parsing — if it's a JSON array/object, use it as such so handlers get
        // proper List/Map types instead of raw strings.
        try {
          final parsed = jsonDecode(val);
          if (parsed is List || parsed is Map) val = parsed;
        } catch (_) {}
        params[nameMatch.group(1)!] = val;
      }
      calls.add(ToolCall(
        id: 'call_content_$idx',
        name: name,
        arguments: jsonEncode(params),
      ));
      idx++;
    }
    return calls.isEmpty ? null : calls;
  }

  // Compiled-once display cleaning regexes
  static final _sInvokeRe = RegExp(r'<invoke\b[^>]*>.*?</invoke>', dotAll: true);
  static final _sParamRe = RegExp(r'<parameter\b[^>]*>.*?</parameter>', dotAll: true);
  static final _sTagRe = RegExp(r'</?(?:invoke|parameter|tool_calls)\b[^>]*>', dotAll: true);
  static final _sCallCnRe = RegExp(r'[（(]\s*调用[\s\S]*?[）)]');
  static final _sCallEnRe = RegExp(r"(?:I(?:'ll|'m|'ve|\s+(?:will|can|should|must))\s+)?(?:call(?:ing|ed)?|invok(?:ing|ed)?|us(?:ing|ed)|let\s+me\s+call)\s+(?:the\s+)?\w+\s*(?:tool|function)?[.!，。]?");
  static final _sHtmlRe = RegExp(r'```html?\s*\n[\s\S]*?```', dotAll: true);
  static final _sCssRe = RegExp(r'```css\s*\n[\s\S]*?```', dotAll: true);
  static final _sBlankRe = RegExp(r'\n{3,}');
  // DSML format: <|DSML|invoke name="...">...</|DSML|invoke>  (supports 0-2 pipes)
  static final _sDsmlBlock = RegExp(r'<\s*\|*\s*DSML\s*\|*\s*\w+\b[^>]*>.*?</\s*\|*\s*DSML\s*\|*\s*\w+\s*>', dotAll: true);
  static final _sDsmlTag = RegExp(r'</?\s*\|*\s*DSML\s*\|*\s*\w+[^>]*>', dotAll: true);

  /// Strip XML tool call blocks from content for clean display.
  static String stripToolCallsFromContent(String content) {
    var c = content;
    c = c.replaceAll(_sInvokeRe, '');
    c = c.replaceAll(_sParamRe, '');
    c = c.replaceAll(_sTagRe, '');
    c = c.replaceAll(_sCallCnRe, '');
    c = c.replaceAll(_sCallEnRe, '');
    c = c.replaceAll(_sHtmlRe, '');
    c = c.replaceAll(_sCssRe, '');
    c = c.replaceAll(_sBlankRe, '\n\n');
    c = c.replaceAll(_sDsmlBlock, '');
    c = c.replaceAll(_sDsmlTag, '');
    return c.trim();
  }

  static AgentState stateForTool(String name) {
    switch (name) {
      case 'web_search':
      case 'web_extract':
      case 'fetch_url':
        return AgentState.searching;
      case 'run_code':
        return AgentState.coding;
      case 'read_file':
        return AgentState.reading;
      case 'write_file':
      case 'delete_file':
        return AgentState.writing;
      case 'delegate_task':
        return AgentState.thinking;
      default:
        return AgentState.thinking;
    }
  }

  /// Execute tools with parallel where safe, preserving original order.
  /// CRITICAL: results must be in the SAME order as input calls (caller matches by index).
  Future<List<Map<String, dynamic>>> execute(List<ToolCall> calls) async {
    if (calls.isEmpty) return [];

    // Build a map: index → result. Execute parallel-safe calls concurrently,
    // then fill in sequential calls in order.
    final results = List<Map<String, dynamic>?>.filled(calls.length, null);

    // First pass: identify parallel-safe indices
    final parallelIndices = <int>[];
    for (int i = 0; i < calls.length; i++) {
      if (_canParallel(calls[i].name)) {
        parallelIndices.add(i);
      }
    }

    // Execute parallel-safe calls concurrently
    if (parallelIndices.isNotEmpty) {
      onStateChange?.call(stateForTool(calls[parallelIndices.first].name));
      final futures = parallelIndices.map((i) async {
        final r = await _executeOne(calls[i]);
        results[i] = r;
      });
      await Future.wait(futures);
    }

    // Second pass: fill remaining sequential calls in order
    for (int i = 0; i < calls.length; i++) {
      if (results[i] != null) continue; // Already done in parallel
      onStateChange?.call(stateForTool(calls[i].name));
      results[i] = await _executeOne(calls[i]);
    }

    onStateChange?.call(AgentState.thinking);
    return results.cast<Map<String, dynamic>>();
  }

  bool _canParallel(String name) {
    const parallelSafe = {
      'web_search', 'web_extract', 'fetch_url', 'get_time', 'get_battery',
      'get_volume', 'get_brightness', 'get_device_info', 'get_clipboard',
      'search_history', 'search_memory', 'list_memories', 'list_files',
      'read_file', 'list_installed_apps',
    };
    return parallelSafe.contains(name);
  }

  Future<Map<String, dynamic>> _executeOne(ToolCall call) async {
    onToolProgress?.call(call.name, 'running');

    try {
      // delegate_task spawns sub-agents that may need up to 120s internally;
      // skip the per-tool timeout so the sub-agent's own outer timeout governs.
      final String result;
      if (call.name == 'delegate_task') {
        // Sub-agents have their own 120s timeout — don't double-wrap.
        result = await _registry.dispatch(call.name, call.args);
      } else if (const {'web_search', 'web_extract', 'fetch_url'}.contains(call.name)) {
        // Web operations can be slow (network latency, large pages).
        result = await _withTimeout(
          () => _registry.dispatch(call.name, call.args),
          const Duration(seconds: 60),
        );
      } else {
        result = await _withTimeout(
          () => _registry.dispatch(call.name, call.args),
          const Duration(seconds: 25),
        );
      }

      onToolProgress?.call(call.name, 'done');
      final truncated = _truncate(result, 3000);

      return {
        'role': 'tool',
        'tool_call_id': call.id,
        'content': truncated,
      };
    } catch (e) {
      onToolProgress?.call(call.name, 'failed');
      return {
        'role': 'tool',
        'tool_call_id': call.id,
        'content': jsonEncode({'error': _cleanError(e)}),
      };
    }
  }

  Future<String> _withTimeout(Future<String> Function() fn, Duration timeout) async {
    return fn().timeout(timeout, onTimeout: () {
      throw TimeoutException('工具调用超时');
    });
  }

  String _truncate(String result, int maxLen) {
    if (result.length <= maxLen) return result;
    try {
      final parsed = jsonDecode(result);
      if (parsed is Map) {
        if (parsed['content'] is String && (parsed['content'] as String).length > maxLen) {
          parsed['content'] = '${(parsed['content'] as String).substring(0, maxLen)}…[truncated]';
          parsed['_truncated'] = true;
        }
        if (parsed['results'] is List) {
          final list = parsed['results'] as List;
          if (list.length > 5) {
            parsed['results'] = list.sublist(0, 5);
            parsed['_truncated'] = true;
            parsed['_total_results'] = list.length;
          }
        }
        final truncated = jsonEncode(parsed);
        if (truncated.length > maxLen) {
          return '${truncated.substring(0, maxLen)}…[truncated]';
        }
        return truncated;
      }
    } catch (_) {}
    return '${result.substring(0, maxLen)}…[truncated]';
  }

  String _cleanError(Object e) {
    final s = e.toString();
    if (s.length > 200) return '${s.substring(0, 200)}…';
    return s;
  }
}