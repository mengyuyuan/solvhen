// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 子代理服务——委派子任务给独立Agent执行
// ═══════════════════════════════════════════════════════════════

library;

/// Architecture: same-process, separate context, configurable toolset.
/// V2.1: prevent recursive delegation, add outer timeout, filter delegation toolset.

import 'dart:async';
import 'dart:convert';
import 'api_service.dart';
import 'tool_executor.dart';
import '../tools/tool_registry.dart';
import '../models/message.dart';

/// 子代理服务——委派独立任务
/// ⚠️ 子代理无父级记忆——需通过context传递全部必要信息
class SubAgentConfig {
  final String goal;
  final String? context;
  final List<String>? toolsets;
  final int maxIterations;
  final String? model;

  const SubAgentConfig({
    required this.goal,
    this.context,
    this.toolsets,
    this.maxIterations = 4,
    this.model,
  });
}

/// 子代理服务——委派独立任务
/// ⚠️ 子代理无父级记忆——需通过context传递全部必要信息
class SubAgentResult {
  final String goal;
  final String summary;
  final bool success;
  final int iterations;
  final String? error;

  const SubAgentResult({
    required this.goal,
    required this.summary,
    required this.success,
    this.iterations = 0,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'goal': goal,
    'summary': summary,
    'success': success,
    'iterations': iterations,
    if (error != null) 'error': error,
  };
}

/// 子代理服务——委派独立任务
/// ⚠️ 子代理无父级记忆——需通过context传递全部必要信息
class SubAgentRunner {
  static final SubAgentRunner _instance = SubAgentRunner._();
  factory SubAgentRunner() => _instance;
  SubAgentRunner._();

  final ApiService _api = ApiService();
  final ToolRegistry _registry = ToolRegistry();

  /// Run a single sub-agent task with isolated context and outer timeout.
  Future<SubAgentResult> run(SubAgentConfig config) async {
    try {
      return await _runInternal(config).timeout(
        const Duration(seconds: 120),
        onTimeout: () => SubAgentResult(
          goal: config.goal,
          summary: '',
          success: false,
          error: '子agent超时(120s)',
        ),
      );
    } catch (e) {
      return SubAgentResult(
        goal: config.goal,
        summary: '',
        success: false,
        error: e.toString().length > 200
            ? '${e.toString().substring(0, 200)}…'
            : e.toString(),
      );
    }
  }

  Future<SubAgentResult> _runInternal(SubAgentConfig config) async {
    final subRegistry = _buildRegistry(config.toolsets);

    final systemPrompt = '''
你是 Solvhen 的一个专注子分身。你只有一个任务。

任务目标：${config.goal}
${config.context != null ? '\n背景信息：${config.context}' : ''}

规则：
- 只做任务目标相关的事。不问问题，不聊天。
- 有工具就用，没有就基于知识回答。
- 完成后给出简洁的结论/结果。
- 一句话能说完就不用两句话。
- 不要说你"会"做什么——直接做，直接给结果。

完成你的任务。现在开始。''';

    final history = <Message>[
      Message(content: config.goal, role: 'user', timestamp: DateTime.now()),
    ];

    int iterations = 0;
    final maxIter = config.maxIterations;

    var result = await _api.chatWithTools(
      systemPrompt: systemPrompt,
      history: [],
      userMessage: config.goal,
      tools: subRegistry.getToolDefs(),
    ).timeout(const Duration(seconds: 60));

    while (result.toolCalls != null &&
           result.toolCalls!.isNotEmpty &&
           iterations < maxIter) {
      iterations++;

      final executor = ToolExecutor(registry: subRegistry);
      final toolResults = await executor.execute(result.toolCalls!);

      final assistantMsg = Message(
        content: ToolExecutor.stripToolCallsFromContent(
            result.content.isNotEmpty ? result.content : ''),
        role: 'assistant',
        timestamp: DateTime.now(),
        toolCallsJson: result.rawToolCalls != null
            ? _jsonEncodeSafe(result.rawToolCalls)
            : null,
      );
      history.add(assistantMsg);

      for (int i = 0; i < result.toolCalls!.length && i < toolResults.length; i++) {
        final r = toolResults[i];
        history.add(Message(
          content: r['content'] as String,
          role: 'tool',
          toolCallId: r['tool_call_id'] as String?,
          timestamp: DateTime.now(),
        ));
      }

      // Follow-up WITHOUT tools — force text-only continuation.
      // No fake "继续" user message — let the model naturally respond to tool results.
      // Check iteration budget BEFORE making the follow-up call to avoid
      // wasting an API round-trip whose tool_calls would never be processed.
      if (iterations >= maxIter) break;

      result = await _api.chatWithTools(
        systemPrompt: systemPrompt,
        history: history,
        userMessage: '',
        tools: const [],
      );
    }

    final summary = ToolExecutor.stripToolCallsFromContent(
        result.content.isNotEmpty ? result.content : '任务完成。');
    return SubAgentResult(
      goal: config.goal,
      summary: _cleanSummary(summary),
      success: true,
      iterations: iterations,
    );
  }

  Future<List<SubAgentResult>> runParallel(List<SubAgentConfig> configs) async {
    final futures = configs.map((c) => run(c));
    return Future.wait(futures);
  }

  /// Build a tool registry with only the requested toolsets.
  /// ALWAYS excludes 'delegation' to prevent recursive sub-agent spawning.
  ToolRegistry _buildRegistry(List<String>? toolsets) {
    final subRegistry = ToolRegistry.isolated();
    for (final name in _registry.names) {
      final entry = _registry[name];
      if (entry == null) continue;
      // NEVER allow sub-agents to spawn their own sub-agents
      if (entry.toolset == 'delegation') continue;
      if (toolsets == null || toolsets.isEmpty || toolsets.contains(entry.toolset)) {
        subRegistry.register(entry);
      }
    }
    return subRegistry;
  }

  String _cleanSummary(String text) {
    var cleaned = text.replaceAll(RegExp(r'[（(]\s*调用\s+\w+[^）)]*[）)]'), '');
    cleaned = cleaned.trim();
    if (cleaned.isEmpty) cleaned = '完成。';
    if (cleaned.length > 800) cleaned = '${cleaned.substring(0, 800)}…';
    return cleaned;
  }

  String _jsonEncodeSafe(dynamic obj) {
    try {
      return jsonEncode(obj);
    } catch (_) {
      return '[]';
    }
  }
}
