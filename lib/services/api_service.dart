import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/message.dart';
import 'database_service.dart';
import 'tool_executor.dart';

class ApiService {
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
    headers: {'Content-Type': 'application/json'},
  ));

  /// Streaming chat — returns full content via onChunk callback.
  /// Throws on error so caller can handle gracefully.
  Future<String> chatStream({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    void Function(String chunk)? onChunk,
  }) async {
    final cfg = await DB.getConfig();
    final url = '${cfg['base_url']}/chat/completions';
    final key = cfg['api_key'] ?? '';
    final model = cfg['model'] ?? 'deepseek-v4-pro';
    if (key.isEmpty) throw Exception('请先设置API Key');

    final msgs = _buildMessages(systemPrompt, history, userMessage);

    final resp = await dio.post(url,
      options: Options(
        headers: {'Authorization': 'Bearer $key'},
        responseType: ResponseType.stream,
      ),
      data: {'model': model, 'messages': msgs, 'stream': true, 'temperature': 0.8, 'max_tokens': 2048},
    );

    final buf = StringBuffer();
    await for (final chunk in (resp.data as ResponseBody).stream) {
      for (final line in utf8.decode(chunk).split('\n')) {
        if (line.startsWith('data: ') && line != 'data: [DONE]') {
          try {
            final c = jsonDecode(line.substring(6))['choices']?[0]?['delta']?['content'];
            if (c != null) { buf.write(c); onChunk?.call(c); }
          } catch (_) { /* skip malformed SSE chunk */ }
        }
      }
    }
    // Strip XML tool calls from streaming output — DeepSeek may embed
    // <invoke> blocks even in streaming responses without tools.
    return ToolExecutor.stripToolCallsFromContent(buf.toString());
  }

  /// Non-streaming chat WITH native function calling.
  /// Returns (content, tool_calls if any, raw tool_calls JSON for history).
  /// Throws on error so caller can handle gracefully.
  Future<({String content, List<ToolCall>? toolCalls, List<dynamic>? rawToolCalls})> chatWithTools({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 4096,
  }) async {
    final cfg = await DB.getConfig();
    final url = '${cfg['base_url']}/chat/completions';
    final key = cfg['api_key'] ?? '';
    final model = cfg['model'] ?? 'deepseek-v4-pro';
    if (key.isEmpty) throw Exception('请先设置API Key');

    final msgs = _buildMessages(systemPrompt, history, userMessage);

    final body = <String, dynamic>{
      'model': model,
      'messages': msgs,
      'stream': false,
      'temperature': 0.8,
      'max_tokens': maxTokens,
    };
    if (tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    final resp = await dio.post(url,
      options: Options(headers: {'Authorization': 'Bearer $key'}),
      data: body,
    );

    final choice = resp.data['choices']?[0];
    final msg = choice?['message'] as Map<String, dynamic>? ?? {};
    var content = (msg['content'] as String?) ?? '';
    var toolCalls = ToolExecutor.parseToolCalls(msg);
    var rawToolCalls = msg['tool_calls'] as List<dynamic>?;

    // Fallback: DeepSeek returns tool calls as XML in content text
    // (when tool_calls array is empty/null but content has XML invoke format)
    // Always attempt to parse XML from content — don't rely on contains()
    // which may return false positives due to encoding issues.
    if (toolCalls == null) {
      if (kDebugMode) {
        debugPrint('[API-RAW] has_tools=${tools.isNotEmpty} native_tc=${rawToolCalls?.length ?? 0} content_len=${content.length}');
        if (content.isNotEmpty) {
          final codes = content.substring(0, content.length < 30 ? content.length : 30).codeUnits;
          debugPrint('[API-HEX] first 30 bytes hex: ${codes.map((c) => c.toRadixString(16).padLeft(2, "0")).join(" ")}');
        }
        if (content.isNotEmpty && content.length < 500) {
          debugPrint('[API-RAW-CONTENT] $content');
        }
      }
      final parsedFromXml = ToolExecutor.parseToolCallsFromContent(content);
      if (parsedFromXml != null) {
        if (kDebugMode) debugPrint('[API-XML] parsed ${parsedFromXml.length} tool calls from XML');
        toolCalls = parsedFromXml;
        content = ToolExecutor.stripToolCallsFromContent(content);
        rawToolCalls = toolCalls!.map((tc) => {
          'id': tc.id,
          'type': 'function',
          'function': {'name': tc.name, 'arguments': tc.arguments},
        }).toList();
      } else {
        // No XML tool calls found — still strip any residual XML for clean display
        content = ToolExecutor.stripToolCallsFromContent(content);
      }
    } else {
      // Always strip XML from content — DeepSeek may embed invoke blocks
      // in content even when proper tool_calls array is present.
      content = ToolExecutor.stripToolCallsFromContent(content);
    }

    return (content: content, toolCalls: toolCalls, rawToolCalls: rawToolCalls);
  }

  List<Map<String, dynamic>> _buildMessages(
    String prompt, List<Message> history, String userMsg,
  ) {
    final msgs = <Map<String, dynamic>>[{'role': 'system', 'content': prompt}];
    for (final m in history) {
      final msg = <String, dynamic>{'role': m.role, 'content': m.content};
      if (m.role == 'tool' && m.toolCallId != null) {
        msg['tool_call_id'] = m.toolCallId;
      }
      if (m.role == 'assistant' && m.toolCallsJson != null) {
        try {
          msg['tool_calls'] = jsonDecode(m.toolCallsJson!);
        } catch (_) {
          // Corrupted JSON — skip, message will still be sent without tool_calls
        }
      }
      msgs.add(msg);
    }
    if (userMsg.isNotEmpty) {
      msgs.add({'role': 'user', 'content': userMsg});
    }
    // userMsg intentionally skipped when empty — follow-up tool calls
    // don't need a fake "continue" message injected into history
    return msgs;
  }

  /// Lightweight non-streaming call for memory consolidation.
  /// No tools, no history — just system prompt + transcript.
  Future<String> consolidate({
    required String systemPrompt,
    required String transcript,
    String model = 'deepseek-v4-flash',
  }) async {
    final cfg = await DB.getConfig();
    final url = '${cfg['base_url']}/chat/completions';
    final key = cfg['api_key'] ?? '';
    if (key.isEmpty) return '{}';

    try {
      final resp = await dio.post(url,
        options: Options(headers: {'Authorization': 'Bearer $key'}),
        data: {
          'model': model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': transcript},
          ],
          'stream': false,
          'temperature': 0.3, // Low temp for structured extraction
          'max_tokens': 1024,
        },
      );
      return (resp.data['choices']?[0]?['message']?['content'] as String?) ?? '{}';
    } on DioException {
      return '{}';
    } on Exception catch (_) {
      return '{}';
    }
  }
}
