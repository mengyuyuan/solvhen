// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// API通信服务——流式对话、函数调用、记忆整合，含模型链动态路由+错误分类
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/message.dart';
import '../models/llm_provider.dart';
import '../core/agent/cancellation.dart';
import '../core/llm/llm_client.dart';
import '../core/llm/llm_config_store.dart';
import 'database_service.dart';
import 'tool_executor.dart';

// ═══════════════════════════════════════════════
// API Usage — real token count from API response
// ═══════════════════════════════════════════════

typedef ApiUsage = LlmUsage;

// ═══════════════════════════════════════════════
// API Error exceptions — typed so UI can react
// ═══════════════════════════════════════════════

class ApiBalanceException implements Exception {
  final String message;
  const ApiBalanceException(this.message);
  @override
  String toString() => 'ApiBalanceException: $message';
}

class ApiRateLimitException implements Exception {
  final String message;
  const ApiRateLimitException(this.message);
  @override
  String toString() => 'ApiRateLimitException: $message';
}

class ApiAuthException implements Exception {
  final String message;
  const ApiAuthException(this.message);
  @override
  String toString() => 'ApiAuthException: $message';
}

class ApiService implements LlmClient {
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
    headers: {'Content-Type': 'application/json'},
    validateStatus: (s) => s != null && s < 500, // let us handle 4xx in code
  ));

  // ═══════════════════════════════════════════════
  // ERROR DETECTION — classify HTTP errors
  // ═══════════════════════════════════════════════

  Never _throwApiError(int? statusCode, String? body) {
    final msg = _extractErrorMessage(body);
    switch (statusCode) {
      case 402:
        throw const ApiBalanceException('API余额已用尽，请前往对应平台充值或更换API Key');
      case 429:
        throw ApiRateLimitException(
            msg.isNotEmpty ? '请求太频繁：$msg' : '请求太频繁，请稍后再试');
      case 401:
        throw ApiAuthException(
            msg.isNotEmpty ? 'API Key无效：$msg' : 'API Key无效，请检查或更换');
      case 403:
        throw ApiAuthException(
            msg.isNotEmpty ? 'API访问被拒：$msg' : 'API访问被拒绝，请检查Key权限或更换');
      default:
        throw Exception(msg.isNotEmpty ? msg : 'API请求失败 (HTTP $statusCode)');
    }
  }

  String _extractErrorMessage(String? body) {
    if (body == null || body.isEmpty) return '';
    try {
      final json = jsonDecode(body);
      return (json['error']?['message'] as String?) ?? '';
    } catch (_) {
      if (body.length <= 120) return body;
      return '${body.substring(0, 120)}…';
    }
  }

  ApiUsage? _extractUsage(Response resp) {
    final usage = resp.data is Map ? resp.data['usage'] : null;
    if (usage is Map<String, dynamic>) return LlmUsage.fromJson(usage);
    return null;
  }

  /// Resolve active model from chain config, falling back to legacy config.
  Future<({String url, String model, String key})> _resolveChain() async {
    final cfg = await DB.getConfig();
    final store = LlmConfigStore();
    final chain = await store.loadChain();
    final slot = chain?.activeSlot;
    if (slot != null) {
      final vendor = findVendor(slot.vendorId);
      final baseUrl = slot.customUrl?.isNotEmpty == true
          ? slot.customUrl!
          : (vendor?.defaultUrl ??
              cfg['base_url'] ??
              'https://api.deepseek.com/v1');
      final key = slot.apiKey?.isNotEmpty == true
          ? slot.apiKey!
          : await store.primaryKey();
      return (url: _chatUrl(baseUrl), model: slot.modelId, key: key);
    }
    final url = _chatUrl(cfg['base_url'] ?? 'https://api.deepseek.com/v1');
    final model = cfg['model'] ?? 'deepseek-v4-pro';
    final key = await store.primaryKey();
    return (url: url, model: model, key: key);
  }

  String _chatUrl(String baseUrl) {
    final clean = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return clean.endsWith('/chat/completions')
        ? clean
        : '$clean/chat/completions';
  }

  CancelToken? _cancelToken(AgentCancellationToken? cancellation) {
    if (cancellation == null) return null;
    final token = CancelToken();
    if (cancellation.isCancelled) {
      token.cancel('agent_cancelled');
    } else {
      unawaited(cancellation.whenCancelled.then((_) {
        if (!token.isCancelled) token.cancel('agent_cancelled');
      }));
    }
    return token;
  }

  /// Streaming chat — returns full content via onChunk callback.
  /// Returns (content, api usage). Usage may be null for streaming.
  /// Throws typed exceptions on API errors.
  @override
  Future<({String content, LlmUsage? usage})> chatStream({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    void Function(String chunk)? onChunk,
    AgentCancellationToken? cancellation,
  }) async {
    final chain = await _resolveChain();
    if (chain.key.isEmpty) throw const ApiAuthException('请先设置API Key');

    final msgs = _buildMessages(systemPrompt, history, userMessage);

    Response<dynamic> resp;
    try {
      resp = await dio.post(
        chain.url,
        cancelToken: _cancelToken(cancellation),
        options: Options(
          headers: {'Authorization': 'Bearer ${chain.key}'},
          responseType: ResponseType.stream,
        ),
        data: {
          'model': chain.model,
          'messages': msgs,
          'stream': true,
          'temperature': 0.8,
          'max_tokens': 2048
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const AgentCancelledException();
      final errMsg = e.type == DioExceptionType.connectionTimeout
          ? '连接超时，请检查网络'
          : e.type == DioExceptionType.receiveTimeout
              ? '服务器响应超时，请重试'
              : '网络错误：${e.message ?? "未知"}';
      throw Exception(errMsg);
    }

    final statusCode = resp.statusCode ?? 0;
    if (statusCode >= 400) {
      // For streaming errors, read the error body
      _throwApiError(statusCode, null);
    }

    final buf = StringBuffer();
    LlmUsage? usage;
    final lines = (resp.data as ResponseBody)
        .stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final rawLine in lines) {
      cancellation?.throwIfCancelled();
      final line = rawLine.trimRight();
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trimLeft();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final data = jsonDecode(payload);
        final c = data['choices']?[0]?['delta']?['content'];
        if (c is String && c.isNotEmpty) {
          buf.write(c);
          onChunk?.call(c);
        }
        final u = data['usage'];
        if (u is Map<String, dynamic>) usage = LlmUsage.fromJson(u);
      } catch (_) {
        // Ignore malformed events without discarding adjacent buffered events.
      }
    }
    return (
      content: ToolExecutor.stripToolCallsFromContent(buf.toString()),
      usage: usage
    );
  }

  /// Non-streaming chat WITH native function calling.
  /// Returns (content, tool_calls if any, raw tool_calls JSON for history, api usage).
  /// Throws typed exceptions (ApiBalanceException etc.) on API errors.
  @override
  Future<
      ({
        String content,
        List<ToolCall>? toolCalls,
        List<dynamic>? rawToolCalls,
        LlmUsage? usage
      })> chatWithTools({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 4096,
    AgentCancellationToken? cancellation,
  }) async {
    final chain = await _resolveChain();
    if (chain.key.isEmpty) throw const ApiAuthException('请先设置API Key');

    final msgs = _buildMessages(systemPrompt, history, userMessage);

    final body = <String, dynamic>{
      'model': chain.model,
      'messages': msgs,
      'stream': false,
      'temperature': 0.8,
      'max_tokens': maxTokens,
    };
    if (tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    Response resp;
    try {
      resp = await dio.post(
        chain.url,
        cancelToken: _cancelToken(cancellation),
        options: Options(headers: {'Authorization': 'Bearer ${chain.key}'}),
        data: body,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const AgentCancelledException();
      // Network errors (timeout, DNS, etc.) — no HTTP response
      final errMsg = e.type == DioExceptionType.connectionTimeout
          ? '连接超时，请检查网络'
          : e.type == DioExceptionType.receiveTimeout
              ? '服务器响应超时，请重试'
              : '网络错误：${e.message ?? "未知"}';
      throw Exception(errMsg);
    }

    // Check for API-level errors (4xx)
    final statusCode = resp.statusCode ?? 0;
    if (statusCode >= 400) {
      _throwApiError(
          statusCode, resp.data is String ? resp.data as String : null);
    }

    final choice = resp.data['choices']?[0];
    final msg = choice?['message'] as Map<String, dynamic>? ?? {};
    var content = (msg['content'] as String?) ?? '';
    var toolCalls = ToolExecutor.parseToolCalls(msg);
    var rawToolCalls = msg['tool_calls'] as List<dynamic>?;

    // Fallback: DeepSeek returns tool calls as XML in content text
    if (toolCalls == null) {
      if (kDebugMode) {
        debugPrint(
            '[API-RAW] has_tools=${tools.isNotEmpty} native_tc=${rawToolCalls?.length ?? 0} content_len=${content.length}');
        if (content.isNotEmpty) {
          final codes = content
              .substring(0, content.length < 30 ? content.length : 30)
              .codeUnits;
          debugPrint(
              '[API-HEX] first 30 bytes hex: ${codes.map((c) => c.toRadixString(16).padLeft(2, "0")).join(" ")}');
        }
      }
      final parsedFromXml = ToolExecutor.parseToolCallsFromContent(content);
      if (parsedFromXml != null) {
        if (kDebugMode) {
          debugPrint(
              '[API-XML] parsed ${parsedFromXml.length} tool calls from XML');
        }
        toolCalls = parsedFromXml;
        content = ToolExecutor.stripToolCallsFromContent(content);
        rawToolCalls = toolCalls
            .map((tc) => {
                  'id': tc.id,
                  'type': 'function',
                  'function': {'name': tc.name, 'arguments': tc.arguments},
                })
            .toList();
      } else {
        content = ToolExecutor.stripToolCallsFromContent(content);
      }
    } else {
      content = ToolExecutor.stripToolCallsFromContent(content);
    }

    final usage = _extractUsage(resp);
    return (
      content: content,
      toolCalls: toolCalls,
      rawToolCalls: rawToolCalls,
      usage: usage
    );
  }

  List<Map<String, dynamic>> _buildMessages(
    String prompt,
    List<Message> history,
    String userMsg,
  ) {
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': prompt}
    ];
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
    final chain = await _resolveChain();
    if (chain.key.isEmpty) return '{}';

    try {
      final resp = await dio.post(
        chain.url,
        options: Options(headers: {'Authorization': 'Bearer ${chain.key}'}),
        data: {
          'model': chain.model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': transcript},
          ],
          'stream': false,
          'temperature': 0.3, // Low temp for structured extraction
          'max_tokens': 1024,
        },
      );
      return (resp.data['choices']?[0]?['message']?['content'] as String?) ??
          '{}';
    } on DioException {
      return '{}';
    } on Exception catch (_) {
      return '{}';
    }
  }
}
