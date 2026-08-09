/// Solvhen AI手机智能体 — 聊天状态管理（Riverpod StateNotifier）
/// 核心状态机：管理消息历史、LLM 请求、工具调用循环、TTS 语音输出。
///
/// 架构要点：
/// - ChatState 是不可变数据类，通过 copyWith 更新
/// - send() 是主流程：user msg → API chatWithTools → 工具循环 → chatStream 最终回复 → TTS
/// - 使用可取消 Timer 避免 TTS 竞态条件
/// - 支持主动推送通知给用户
library;

import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/message.dart';
import '../services/database_service.dart';
import '../services/api_service.dart';
import '../services/prompt_builder.dart';
import '../services/tool_executor.dart';
import '../services/skill_loader.dart';
import '../services/notification_service.dart';
import '../services/voice_service.dart';
import '../tools/tool_registry.dart';
import '../core/agent/agent_execution_config.dart';
import '../core/agent/agent_run.dart';
import '../core/agent/agent_runtime.dart';
import '../core/agent/cancellation.dart';
import '../core/llm/llm_client.dart';
import '../core/security/tool_security.dart';
import 'agent_avatar.dart';
import 'webview_canvas.dart';

/// 全局聊天状态 Provider
final chatProvider =
    StateNotifierProvider<ChatNotifier, ChatState>((ref) => ChatNotifier(ref));

/// A final model response is one semantic message. Keeping Markdown blocks,
/// lists and code fences together is essential for correct rendering and also
/// avoids inflating the database/list with one bubble per sentence.
@visibleForTesting
List<Message> buildFinalAssistantMessages({
  required String content,
  required int conversationId,
  required DateTime timestamp,
}) =>
    [
      Message(
        content: content,
        role: 'assistant',
        timestamp: timestamp,
        conversationId: conversationId,
      ),
    ];

/// 聊天状态：不可变数据类，包含消息列表、加载状态、流式文本、token 用量等
class ChatState {
  final List<Message> messages;
  final bool loading;
  final String streaming;
  final String? error;
  final bool ready;
  final int conversationId;
  final int tokenCount; // 本地估算的 token 数
  final int contextLimit; // 模型上下文窗口大小
  final double contextRatio; // API 返回的实际上下文比例（优先于 local 估算）
  final int apiPromptTokens; // API 返回的 prompt token 数
  final int apiCompletionTokens; // API 返回的 completion token 数
  final AgentState agentState; // Agent 头像状态（思考/编码/搜索等）
  final String agentToolStatus; // 当前工具状态文本（如 "执行中…"）
  final DateTime? sendStartedAt; // 发送开始时间（用于思考动画计时）
  final bool ttsSpeaking; // TTS 是否正在播放
  final AgentRunState runState;
  final ToolApprovalRequest? pendingApproval;
  final AgentBudgetRequest? pendingBudget;

  const ChatState({
    this.messages = const [],
    this.loading = false,
    this.streaming = '',
    this.error,
    this.ready = false,
    this.conversationId = 1,
    this.tokenCount = 0,
    this.contextLimit = 1048576,
    this.contextRatio = 0.0,
    this.apiPromptTokens = 0,
    this.apiCompletionTokens = 0,
    this.agentState = AgentState.idle,
    this.agentToolStatus = '',
    this.sendStartedAt,
    this.ttsSpeaking = false,
    this.runState = AgentRunState.idle,
    this.pendingApproval,
    this.pendingBudget,
  });

  /// 不可变拷贝：使用 ?? 运算符保持未传字段不变。
  /// clearErr/clearSendTime 标志允许显式清空字段（因为 null 表示"保持不变"）。
  ChatState copyWith({
    List<Message>? messages,
    bool? loading,
    String? streaming,
    String? error,
    bool? ready,
    int? conversationId,
    int? tokenCount,
    int? contextLimit,
    double? contextRatio,
    int? apiPromptTokens,
    int? apiCompletionTokens,
    AgentState? agentState,
    String? agentToolStatus,
    DateTime? sendStartedAt,
    bool? ttsSpeaking,
    AgentRunState? runState,
    ToolApprovalRequest? pendingApproval,
    AgentBudgetRequest? pendingBudget,
    bool clearSendTime = false,
    bool clearErr = false,
    bool clearPendingApproval = false,
    bool clearPendingBudget = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        streaming: streaming ?? this.streaming,
        error: clearErr ? null : (error ?? this.error),
        ready: ready ?? this.ready,
        conversationId: conversationId ?? this.conversationId,
        tokenCount: tokenCount ?? this.tokenCount,
        contextLimit: contextLimit ?? this.contextLimit,
        contextRatio: contextRatio ?? this.contextRatio,
        apiPromptTokens: apiPromptTokens ?? this.apiPromptTokens,
        apiCompletionTokens: apiCompletionTokens ?? this.apiCompletionTokens,
        agentState: agentState ?? this.agentState,
        agentToolStatus: agentToolStatus ?? this.agentToolStatus,
        sendStartedAt:
            clearSendTime ? null : (sendStartedAt ?? this.sendStartedAt),
        ttsSpeaking: ttsSpeaking ?? this.ttsSpeaking,
        runState: runState ?? this.runState,
        pendingApproval: clearPendingApproval
            ? null
            : (pendingApproval ?? this.pendingApproval),
        pendingBudget:
            clearPendingBudget ? null : (pendingBudget ?? this.pendingBudget),
      );
}

/// 聊天状态管理（Riverpod StateNotifier）
/// 核心流程：用户输入 → API调用 → 流式更新 → 工具循环 → 记忆整合
/// 工具循环由 AgentExecutionConfig 控制；循环次数始终有限且受运行截止时间保护。
class ChatNotifier extends StateNotifier<ChatState> {
  final LlmClient _api = ApiService();
  final AgentRuntime _runtime = AgentRuntime();
  bool _historyReady = false;
  Completer<bool>? _approvalCompleter;
  Completer<bool>? _budgetCompleter;
  String _ttsBuf = ''; // TTS 句子缓冲区：累积流式文本直到遇到句子结束符
  Timer? _ttsTimer; // ⚠️ 可取消的 TTS 完成定时器，避免 Future.delayed 闭包捕获旧状态

  ChatNotifier(Ref ref) : super(const ChatState()) {
    _init();
  }

  /// 初始化：加载技能、消息历史、配置、估算 token
  Future<void> _init() async {
    List<Message> msgs = const [];
    try {
      await SkillLoader.sync();
      final convId = await DB.getActiveConversationId();
      final rows = await DB.getMessages(convId, limit: 50);
      msgs = rows.map((r) => Message.fromMap(r)).toList();
      final cfg = await DB.getConfig();
      final model = cfg['model'] ?? 'deepseek-v4-pro';
      final limit = DB.contextWindow(model);

      final prompt = await PromptBuilder.build(msgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final tokens = PromptBuilder.estimateTokens(prompt, msgs);

      _historyReady = true;
      state = state.copyWith(
        messages: msgs,
        ready: true,
        conversationId: convId,
        tokenCount: tokens,
        contextLimit: limit,
        contextRatio: limit > 0 ? tokens / limit : 0,
      );
    } catch (e) {
      // ⚠️ 即使初始化失败也设为 ready，否则 UI 永远不显示
      _historyReady = true;
      state = state.copyWith(messages: msgs, ready: true, error: '初始化失败: $e');
    }
  }

  /// 从数据库刷新消息列表和 token 计数
  Future<void> refreshFromDB() async {
    final rows = await DB.getMessages(state.conversationId, limit: 50);
    final msgs = rows.map((r) => Message.fromMap(r)).toList();
    final prompt = await PromptBuilder.build(msgs, '',
        toolNames: ToolRegistry().names, conversationId: state.conversationId);
    final tokens = PromptBuilder.estimateTokens(prompt, msgs);
    state = state.copyWith(
        messages: msgs,
        tokenCount: tokens,
        contextRatio: state.contextLimit > 0 ? tokens / state.contextLimit : 0);
  }

  /// 重置消息列表（用于重新生成）
  void resetToMessages(List<Message> msgs) {
    state = state.copyWith(messages: msgs);
  }

  /// 切换对话：加载新对话的消息历史，触发旧对话的摘要合并
  Future<void> switchConversation(int convId) async {
    // Switching conversations is an explicit user cancellation boundary.
    // Never silently ignore it while a tool/stream is winding down: doing so
    // leaves the old native canvas alive while the drawer presents a newly
    // created chat, and the next IME resize can expose that stale surface.
    if (state.loading) cancel();
    final oldConvId = state.conversationId;
    try {
      if (oldConvId != convId) {
        // render_html 是当前对话的临时视觉结果，绝不能泄漏到新对话。
        // 同时确保旧 Android PlatformView 在输入框触发键盘重布局前被卸载。
        await WebViewCanvasController().clearCanvas();
      }
      await DB.setActiveConversation(convId);
      final rows = await DB.getMessages(convId, limit: 50);
      final msgs = rows.map((r) => Message.fromMap(r)).toList();
      final cfg = await DB.getConfig();
      final model = cfg['model'] ?? 'deepseek-v4-pro';
      final limit = DB.contextWindow(model);
      final prompt = await PromptBuilder.build(msgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final tokens = PromptBuilder.estimateTokens(prompt, msgs);
      state = state.copyWith(
          messages: msgs,
          conversationId: convId,
          tokenCount: tokens,
          contextLimit: limit,
          contextRatio: limit > 0 ? tokens / limit : 0);

      PromptBuilder.invalidateStableCache();

      // Memory extraction may call the LLM and take many seconds. The active
      // conversation is already safely switched, so never keep the drawer and
      // input UI blocked on this background maintenance task.
      if (oldConvId != convId && oldConvId > 0) {
        unawaited(PromptBuilder.consolidateConversation(oldConvId));
      }
    } catch (e) {
      debugPrint('[Solvhen] switchConversation failed: $e');
    }
  }

  /// 设置 Agent 状态（头像动画 + 工具状态文本）
  void _setState(AgentState s, [String? status]) {
    state = state.copyWith(agentState: s, agentToolStatus: status ?? '');
  }

  /// 取消当前请求：设置中断标志 + 停止 TTS + 重置状态
  void cancel() {
    _approvalCompleter?.complete(false);
    _approvalCompleter = null;
    _budgetCompleter?.complete(false);
    _budgetCompleter = null;
    unawaited(_runtime.cancel());
    VoiceService().stop();
    _setState(AgentState.idle);
    state = state.copyWith(
      ttsSpeaking: false,
      loading: false,
      runState: AgentRunState.cancelled,
      clearPendingApproval: true,
      clearPendingBudget: true,
      clearSendTime: true,
    );
  }

  void resolveBudgetContinuation(bool approved) {
    final completer = _budgetCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(approved);
    _budgetCompleter = null;
    if (approved) _runtime.active?.extendBudget();
    _runtime.transition(AgentRunState.executing);
    state = state.copyWith(
      runState: AgentRunState.executing,
      clearPendingBudget: true,
    );
  }

  Future<bool> _requestBudgetContinuation(AgentRunSession run) async {
    _budgetCompleter?.complete(false);
    final completer = Completer<bool>();
    _budgetCompleter = completer;
    _runtime.transition(AgentRunState.awaitingApproval);
    state = state.copyWith(
      runState: AgentRunState.awaitingApproval,
      pendingBudget: AgentBudgetRequest(
        usedIterations: run.iterations,
        currentLimit: run.iterationLimit,
        proposedLimit: run.proposedIterationLimit,
        hardLimit: run.hardIterationLimit,
        stepsPerLoop: run.stepsPerLoop,
        currentLoop: run.currentLoop,
        proposedLoop: run.proposedLoop,
        maxLoops: run.effectiveMaxLoops,
      ),
      agentToolStatus: '第 ${run.currentLoop}/${run.effectiveMaxLoops} 轮已用完',
    );
    final remaining = run.remainingDuration;
    final approved = remaining == Duration.zero
        ? false
        : await completer.future.timeout(
            remaining,
            onTimeout: () => false,
          );
    if (identical(_budgetCompleter, completer)) {
      _budgetCompleter = null;
      state = state.copyWith(clearPendingBudget: true);
    }
    return approved;
  }

  void resolveToolApproval(bool approved) {
    final completer = _approvalCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(approved);
    _approvalCompleter = null;
    _runtime.transition(AgentRunState.executing);
    state = state.copyWith(
      runState: AgentRunState.executing,
      clearPendingApproval: true,
    );
  }

  Future<bool> _requestToolApproval(ToolApprovalRequest request) async {
    _approvalCompleter?.complete(false);
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    _runtime.transition(AgentRunState.awaitingApproval);
    state = state.copyWith(
      runState: AgentRunState.awaitingApproval,
      pendingApproval: request,
      agentToolStatus: '等待确认：${request.toolName}',
    );
    final remaining =
        _runtime.active?.remainingDuration ?? const Duration(minutes: 3);
    final approved = remaining == Duration.zero
        ? false
        : await completer.future.timeout(
            remaining,
            onTimeout: () => false,
          );
    if (identical(_approvalCompleter, completer)) {
      _approvalCompleter = null;
      state = state.copyWith(clearPendingApproval: true);
    }
    return approved;
  }

  /// 关闭错误横幅
  void dismissError() {
    state = state.copyWith(clearErr: true);
  }

  /// 中断 TTS 播放：停止语音 + 重置 ttsSpeaking 标志
  void stopSpeaking() {
    VoiceService().stop();
    state = state.copyWith(ttsSpeaking: false);
  }

  /// 主动推送通知到用户设备
  Future<void> push(
      {required String title, required String body, String? payload}) async {
    await NotificationService()
        .show(title: title, body: body, payload: payload);
  }

  // ═══════════════════════════════════════════════════
  // 发送消息主流程
  // ═══════════════════════════════════════════════════

  /// 主发送流程：
  /// 1. 保存用户消息 → 2. API chatWithTools（按用户运行设置循环）
  /// → 3. chatStream 最终回复 → 4. TTS 语音输出 → 5. 保存 AI 消息
  Future<void> send(String text, {bool isVoice = false}) async {
    if (state.loading || !_historyReady) return;

    final convId = state.conversationId;
    final userMsg = Message(
      content: text,
      role: 'user',
      timestamp: DateTime.now(),
      conversationId: convId,
    );
    final db = await DB.database;
    await db.insert('messages', userMsg.toMap());
    await DB.touchConversation(convId);
    await DB.setActiveConversation(convId);
    await DB.setConfig(
        'last_activity_at', DateTime.now().toIso8601String()); // 主动消息冲突检测

    final historyBefore = List<Message>.from(state.messages);
    _setState(AgentState.thinking);

    state = state.copyWith(
      messages: [...state.messages, userMsg],
      loading: true,
      streaming: '',
      sendStartedAt: DateTime.now(),
    );

    final nextHistory = List<Message>.from(historyBefore)..add(userMsg);

    try {
      final executionConfig = await AgentExecutionConfig.load();
      final run = await _runtime.start(
        conversationId: convId,
        origin: ExecutionOrigin.localUser,
        config: executionConfig,
      );
      state = state.copyWith(runState: AgentRunState.planning);
      final registry = ToolRegistry();
      final toolDefs = registry.getToolDefs(origin: ExecutionOrigin.localUser);

      // ── 第一步：chatWithTools（非流式，含工具调用循环）──
      var result = await _api
          .chatWithTools(
            systemPrompt: await PromptBuilder.build(historyBefore, text,
                toolNames: registry.names, conversationId: convId),
            history: historyBefore,
            userMessage: text,
            tools: toolDefs,
            cancellation: run.cancellation,
          )
          .timeout(const Duration(seconds: 120)); // 首次调用宽限到120s

      int totalPromptTokens = result.usage?.promptTokens ?? 0;
      int totalCompletionTokens = result.usage?.completionTokens ?? 0;

      // ── 工具调用循环：每轮步数、循环次数和续批策略均来自运行设置 ──
      while (result.toolCalls != null && result.toolCalls!.isNotEmpty) {
        if (!run.canContinue) {
          if (!run.canExtendBudget) break;
          var continueTools = true;
          switch (run.loopMode) {
            case AgentLoopMode.automatic:
              run.extendBudget();
              state = state.copyWith(
                runState: AgentRunState.executing,
                agentToolStatus:
                    '自动进入第 ${run.currentLoop}/${run.effectiveMaxLoops} 轮',
              );
            case AgentLoopMode.ask:
              final approved = await _requestBudgetContinuation(run);
              if (!approved) continueTools = false;
            case AgentLoopMode.single:
              continueTools = false;
          }
          if (!continueTools) break;
        }
        run.beginIteration();
        final calls = result.toolCalls!;

        // 保存 assistant 消息（含工具调用 JSON）
        final cleanContent =
            ToolExecutor.stripToolCallsFromContent(result.content);
        final toolCallsJson = result.rawToolCalls != null
            ? jsonEncode(result.rawToolCalls)
            : null;
        final assistantMsg = Message(
          content: cleanContent,
          role: 'assistant',
          timestamp: DateTime.now(),
          conversationId: convId,
          toolCallsJson: toolCallsJson,
        );
        await _saveMsg(assistantMsg);
        state = state.copyWith(messages: [...state.messages, assistantMsg]);
        nextHistory.add(assistantMsg);

        // 执行工具调用
        _runtime.transition(AgentRunState.executing);
        state = state.copyWith(runState: AgentRunState.executing);
        _setState(ToolExecutor.stateForTool(calls.first.name), '执行中…');
        final executor = ToolExecutor(
          context: _runtime.toolContext(approval: _requestToolApproval),
          onApproval: _requestToolApproval,
          onStateChange: (s) => _setState(s),
        );
        final toolResults = await executor.execute(calls);

        // 保存工具结果消息
        final newMsgs = List<Message>.of(state.messages, growable: true);
        for (int i = 0; i < calls.length && i < toolResults.length; i++) {
          final r = toolResults[i];
          final toolMsg = Message(
            content: r['content'] as String,
            role: 'tool',
            toolCallId: r['tool_call_id'] as String?,
            timestamp: DateTime.now(),
            conversationId: convId,
          );
          await _saveMsg(toolMsg);
          nextHistory.add(toolMsg);
          newMsgs.add(toolMsg);
        }
        state = state.copyWith(messages: newMsgs);

        // 更新 token 计数
        final midPrompt = await PromptBuilder.build(nextHistory, '',
            toolNames: registry.names, conversationId: convId);
        state = state.copyWith(
          tokenCount: PromptBuilder.estimateTokens(midPrompt, nextHistory),
          apiPromptTokens: totalPromptTokens,
          apiCompletionTokens: totalCompletionTokens,
          contextRatio: state.contextLimit > 0
              ? (totalPromptTokens + totalCompletionTokens) / state.contextLimit
              : 0,
        );

        _setState(AgentState.thinking);
        if (!run.canContinue) break;
        // 下一轮 chatWithTools — 每次刷新工具列表，让 register_tool 新增的工具立即可用
        result = await _api
            .chatWithTools(
              systemPrompt: await PromptBuilder.build(nextHistory, '',
                  toolNames: registry.names, conversationId: convId),
              history: nextHistory,
              userMessage: '',
              tools: registry.getToolDefs(),
              cancellation: run.cancellation,
            )
            .timeout(const Duration(seconds: 60)); // 每轮60s，给无障碍操作留时间

        if (result.usage != null) {
          totalPromptTokens += result.usage!.promptTokens;
          totalCompletionTokens += result.usage!.completionTokens;
        }
      }

      // ── 中断检查 ──
      if (run.cancellation.isCancelled) {
        _setState(AgentState.idle);
        state = state.copyWith(
          loading: false,
          streaming: '',
          runState: AgentRunState.cancelled,
          clearPendingApproval: true,
          clearPendingBudget: true,
          clearSendTime: true,
        );
        return;
      }

      // ── 第二步：chatStream 获取最终回复（流式，实时显示）──
      _runtime.transition(AgentRunState.streaming);
      state = state.copyWith(runState: AgentRunState.streaming);
      _setState(AgentState.speaking);
      _ttsBuf = '';
      final voice = VoiceService();
      // 仅语音输入时启用 TTS
      if (isVoice && voice.volcanoReady) {
        await voice.init();
        state = state.copyWith(ttsSpeaking: true);
      }

      String finalText = '';
      try {
        final prompt = await PromptBuilder.build(nextHistory, '',
            toolNames: ToolRegistry().names, conversationId: convId);
        final streamResult = await _api
            .chatStream(
              systemPrompt: prompt,
              history: nextHistory,
              userMessage: '',
              onChunk: (chunk) {
                final sb = StringBuffer(state.streaming);
                sb.write(chunk);
                state = state.copyWith(streaming: sb.toString());
                _ttsBuf += chunk;
                if (isVoice) _flushTtsSentences(voice);
              },
              cancellation: run.cancellation,
            )
            .timeout(const Duration(seconds: 90)); // 流式最终回复宽限到90s
        finalText = streamResult.content;
      } catch (_) {
        // 流式失败 → 回退到非流式结果
        // ⚠️ 回退内容可能包含工具调用 XML，后续会被 stripToolCallsFromContent 清理
        finalText = result.content.isNotEmpty ? result.content : '（网络超时，请稍后重试）';
      }

      // 清理工具调用标签和空白
      finalText = ToolExecutor.stripToolCallsFromContent(finalText);
      finalText = finalText.trim();
      if (finalText.isEmpty) {
        // 空回复不回显，避免无意义的"好了。"刷屏
        _setState(AgentState.idle);
        state =
            state.copyWith(loading: false, streaming: '', clearSendTime: true);
        await _runtime.complete();
        return;
      }

      // 刷新 TTS 缓冲区中剩余的文本（仅语音输入）
      final remaining = _ttsBuf.trim();
      if (isVoice && remaining.isNotEmpty && remaining.length > 1) {
        unawaited(voice.speakChunk(remaining));
      }

      // One run produces one semantic assistant message. Sentence splitting
      // breaks Markdown headings/lists/code blocks and creates excessive UI
      // bubbles, so preserve the model response exactly as returned.
      final aiMsgs = buildFinalAssistantMessages(
        content: finalText,
        conversationId: convId,
        timestamp: DateTime.now(),
      );
      final batch = db.batch();
      for (final msg in aiMsgs) {
        batch.insert('messages', msg.toMap());
      }
      await batch.commit(noResult: true);
      await DB.touchConversation(convId);

      // Only voice-originated runs show the speaking indicator. Text chat used
      // to flash a false "speaking" state for two seconds after every reply.
      _ttsTimer?.cancel();
      if (isVoice && voice.volcanoReady) {
        state = state.copyWith(ttsSpeaking: true);
        _ttsTimer = Timer(const Duration(seconds: 2), () {
          state = state.copyWith(ttsSpeaking: false);
        });
      } else {
        state = state.copyWith(ttsSpeaking: false);
      }

      // 更新最终 token 计数
      final allMsgs = [...state.messages, ...aiMsgs];
      final newPrompt = await PromptBuilder.build(allMsgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final estimated = PromptBuilder.estimateTokens(newPrompt, allMsgs);

      _setState(AgentState.idle);
      state = state.copyWith(
        messages: [...state.messages, ...aiMsgs],
        loading: false,
        streaming: '',
        tokenCount: estimated,
        apiPromptTokens: totalPromptTokens,
        apiCompletionTokens: totalCompletionTokens,
        contextRatio: state.contextLimit > 0
            ? (totalPromptTokens + totalCompletionTokens) / state.contextLimit
            : 0,
        clearSendTime: true,
        runState: AgentRunState.completed,
      );
      await _runtime.complete();

      // 自动命名：新对话首轮后 LLM 生成标题
      _autoNameConversation(convId, text, finalText);
    } on AgentCancelledException {
      _setState(AgentState.idle);
      state = state.copyWith(
        loading: false,
        streaming: '',
        runState: AgentRunState.cancelled,
        clearPendingApproval: true,
        clearPendingBudget: true,
        clearSendTime: true,
      );
    } on ApiBalanceException catch (e) {
      await _runtime.fail(e);
      _setState(AgentState.idle);
      state = state.copyWith(
          loading: false, streaming: '', error: e.message, clearSendTime: true);
    } on ApiRateLimitException catch (e) {
      await _runtime.fail(e);
      _setState(AgentState.idle);
      state = state.copyWith(
          loading: false, streaming: '', error: e.message, clearSendTime: true);
    } on ApiAuthException catch (e) {
      await _runtime.fail(e);
      _setState(AgentState.idle);
      state = state.copyWith(
          loading: false, streaming: '', error: e.message, clearSendTime: true);
    } catch (e) {
      // ── 兜底：主流程失败时尝试非流式请求 ──
      try {
        final prompt = await PromptBuilder.build(nextHistory, text,
            toolNames: ToolRegistry().names, conversationId: convId);
        _setState(AgentState.speaking);
        final streamResult = await _api
            .chatStream(
              systemPrompt: prompt,
              history: nextHistory,
              userMessage: text,
              onChunk: (c) {
                final b = StringBuffer(state.streaming);
                b.write(c);
                state = state.copyWith(streaming: b.toString());
              },
              cancellation: _runtime.active?.cancellation,
            )
            .timeout(const Duration(seconds: 10));
        final reply = streamResult.content;
        final aiMsg = Message(
          content: reply.isNotEmpty ? reply : '（请求超时，请重试）',
          role: 'assistant',
          timestamp: DateTime.now(),
          conversationId: convId,
        );
        await db.insert('messages', aiMsg.toMap());
        await DB.touchConversation(convId);

        final allMsgs = [...state.messages, aiMsg];
        final newPrompt = await PromptBuilder.build(allMsgs, '',
            toolNames: ToolRegistry().names, conversationId: convId);
        final tokens = PromptBuilder.estimateTokens(newPrompt, allMsgs);

        _setState(AgentState.idle);
        state = state.copyWith(
          messages: [...state.messages, aiMsg],
          loading: false,
          streaming: '',
          tokenCount: tokens,
          contextRatio:
              state.contextLimit > 0 ? tokens / state.contextLimit : 0,
          clearSendTime: true,
          runState: AgentRunState.completed,
        );
        await _runtime.complete();
      } on ApiBalanceException catch (e2) {
        await _runtime.fail(e2);
        _setState(AgentState.idle);
        state = state.copyWith(
            loading: false,
            streaming: '',
            error: e2.message,
            clearSendTime: true);
      } on ApiRateLimitException catch (e2) {
        await _runtime.fail(e2);
        _setState(AgentState.idle);
        state = state.copyWith(
            loading: false,
            streaming: '',
            error: e2.message,
            clearSendTime: true);
      } on ApiAuthException catch (e2) {
        await _runtime.fail(e2);
        _setState(AgentState.idle);
        state = state.copyWith(
            loading: false,
            streaming: '',
            error: e2.message,
            clearSendTime: true);
      } catch (e2) {
        await _runtime.fail(e2);
        _setState(AgentState.idle);
        state = state.copyWith(
          loading: false,
          streaming: '',
          error:
              '请求失败: ${e2.toString().length > 100 ? '${e2.toString().substring(0, 100)}…' : e2}',
          clearSendTime: true,
        );
      }
    }
  }

  /// 从 TTS 缓冲区中刷新完整句子到语音服务。
  /// 句子边界：。！？\n …（实际换行符和中文标点）
  void _flushTtsSentences(VoiceService voice) {
    // ⚠️ 修复：'\n' 匹配实际换行符；之前 '\\n' 只匹配字面量反斜杠+n 两个字符
    const endings = ['。', '！', '？', '\n', '…'];
    while (true) {
      int? cut;
      for (final e in endings) {
        final i = _ttsBuf.indexOf(e);
        if (i != -1 && (cut == null || i < cut)) cut = i;
      }
      if (cut == null) break;

      final sentence = _ttsBuf.substring(0, cut + 1).trim();
      _ttsBuf = _ttsBuf.substring(cut + 1);

      if (sentence.length > 1) {
        voice.speakChunk(sentence);
      }
    }
  }

  /// 保存消息到数据库（失败时记录日志，不阻断主流程）
  Future<void> _saveMsg(Message msg) async {
    try {
      final db = await DB.database;
      await db.insert('messages', msg.toMap());
    } catch (e) {
      debugPrint('[Solvhen] _saveMsg failed: $e');
    }
  }

  /// 自动给新对话命名——首轮后取用户消息前20字做标题
  Future<void> _autoNameConversation(
      int convId, String userMsg, String aiReply) async {
    try {
      final db = await DB.database;
      final rows = await db.query('conversations',
          where: 'id = ?', whereArgs: [convId], limit: 1);
      if (rows.isEmpty) return;
      final title = rows.first['title'] as String? ?? '';
      if (title != '新对话') return; // 不覆盖已命名的
      final short =
          userMsg.length > 20 ? '${userMsg.substring(0, 20)}…' : userMsg;
      await DB.updateConversationTitle(convId, short);
    } catch (_) {}
  }
}
