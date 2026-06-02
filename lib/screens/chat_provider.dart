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
import '../tools/tool_registry.dart';
import 'agent_avatar.dart';

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) => ChatNotifier(ref));

class ChatState {
  final List<Message> messages;
  final bool loading;
  final String streaming;
  final String? error;
  final bool ready;
  final int conversationId;
  final int tokenCount;
  final int contextLimit;
  final double contextRatio;
  final AgentState agentState;
  final String agentToolStatus;
  final DateTime? sendStartedAt; // for elapsed-time display during tool execution

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
    this.agentState = AgentState.idle,
    this.agentToolStatus = '',
    this.sendStartedAt,
  });

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
    AgentState? agentState,
    String? agentToolStatus,
    DateTime? sendStartedAt,
    bool clearSendTime = false,
    bool clearErr = false,
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
        agentState: agentState ?? this.agentState,
        agentToolStatus: agentToolStatus ?? this.agentToolStatus,
        sendStartedAt: clearSendTime ? null : (sendStartedAt ?? this.sendStartedAt),
      );
}

class ChatNotifier extends StateNotifier<ChatState> {
  final ApiService _api = ApiService();
  bool _historyReady = false;
  bool _interrupted = false;

  ChatNotifier(Ref ref) : super(const ChatState()) { _init(); }

  Future<void> _init() async {
    List<Message> msgs = const [];
    try {
      // Sync skills FIRST so PromptBuilder has them available
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
        messages: msgs, ready: true, conversationId: convId,
        tokenCount: tokens, contextLimit: limit,
        contextRatio: limit > 0 ? tokens / limit : 0,
      );
    } catch (e) {
      _historyReady = true;
      state = state.copyWith(messages: msgs, ready: true, error: '初始化失败: $e');
    }
  }

  Future<void> refreshFromDB() async {
    final rows = await DB.getMessages(state.conversationId, limit: 50);
    final msgs = rows.map((r) => Message.fromMap(r)).toList();
    final prompt = await PromptBuilder.build(msgs, '',
        toolNames: ToolRegistry().names, conversationId: state.conversationId);
    final tokens = PromptBuilder.estimateTokens(prompt, msgs);
    state = state.copyWith(messages: msgs, tokenCount: tokens,
      contextRatio: state.contextLimit > 0 ? tokens / state.contextLimit : 0);
  }

  /// Set messages directly (for regenerate/edit). Does NOT save to DB.
  void resetToMessages(List<Message> msgs) {
    state = state.copyWith(messages: msgs);
  }

  Future<void> switchConversation(int convId) async {
    if (state.loading) return;
    final oldConvId = state.conversationId;
    try {
      await DB.setActiveConversation(convId);
      final rows = await DB.getMessages(convId, limit: 50);
      final msgs = rows.map((r) => Message.fromMap(r)).toList();
      final cfg = await DB.getConfig();
      final model = cfg['model'] ?? 'deepseek-v4-pro';
      final limit = DB.contextWindow(model);
      final prompt = await PromptBuilder.build(msgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final tokens = PromptBuilder.estimateTokens(prompt, msgs);
      state = state.copyWith(messages: msgs, conversationId: convId,
        tokenCount: tokens, contextLimit: limit,
        contextRatio: limit > 0 ? tokens / limit : 0);

      if (oldConvId != convId && oldConvId > 0) {
        await PromptBuilder.consolidateConversation(oldConvId);
      }
      // Invalidate stable prompt cache — persona/skills may have changed
      PromptBuilder.invalidateStableCache();
    } catch (_) {
      // Keep current conversation if switch fails — no state change
    }
  }

  void _setState(AgentState s, [String? status]) {
    if (kDebugMode) debugPrint('[ChatProvider] _setState: $s');
    state = state.copyWith(agentState: s, agentToolStatus: status ?? '');
  }

  /// Interrupt the current send() — stops tool loop, preserves partial progress.
  void cancel() {
    _interrupted = true;
    _setState(AgentState.idle);
  }

  // ═══════════════════════════════════════════════════
  // SEND — kept clean. Multi-round tool loop with timeouts.
  // ═══════════════════════════════════════════════════

  Future<void> send(String text) async {
    if (state.loading || !_historyReady) return;
    _interrupted = false;

    final convId = state.conversationId;
    final userMsg = Message(
      content: text, role: 'user', timestamp: DateTime.now(), conversationId: convId,
    );
    final db = await DB.database;
    await db.insert('messages', userMsg.toMap());
    await DB.touchConversation(convId);

    final historyBefore = List<Message>.from(state.messages);
    _setState(AgentState.thinking);

    state = state.copyWith(
      messages: [...state.messages, userMsg],
      loading: true, streaming: '',
      sendStartedAt: DateTime.now(),
    );

    // Accumulate across iterations — never rebuild from scratch
    final nextHistory = List<Message>.from(historyBefore)..add(userMsg);

    try {
      final registry = ToolRegistry();
      final toolDefs = registry.getToolDefs();

      var result = await _api.chatWithTools(
        systemPrompt: await PromptBuilder.build(historyBefore, text,
            toolNames: registry.names, conversationId: convId),
        history: historyBefore, userMessage: text, tools: toolDefs,
      ).timeout(const Duration(seconds: 90));

      int iterations = 0;
      const maxIterations = 8;
      while (result.toolCalls != null &&
             result.toolCalls!.isNotEmpty &&
             iterations < maxIterations) {
        if (_interrupted) break;
        iterations++;
        final calls = result.toolCalls!;

        // Save intermediate assistant message
        final cleanContent = ToolExecutor.stripToolCallsFromContent(result.content);
        if (kDebugMode) {
          debugPrint('[Solvhen] content_len=${result.content.length} clean_len=${cleanContent.length} has_tags=${result.content.contains("<invoke")}');
        }
        final toolCallsJson = result.rawToolCalls != null
            ? jsonEncode(result.rawToolCalls) : null;
        final assistantMsg = Message(
          content: cleanContent, role: 'assistant',
          timestamp: DateTime.now(), conversationId: convId,
          toolCallsJson: toolCallsJson,
        );
        await _saveMsg(assistantMsg);
        state = state.copyWith(messages: [...state.messages, assistantMsg]);
        nextHistory.add(assistantMsg);

        // Execute tools
        _setState(ToolExecutor.stateForTool(calls.first.name), '正在执行…');
        final executor = ToolExecutor(onStateChange: (s) => _setState(s));
        final toolResults = await executor.execute(calls);

        // Batch save + state update for tool results
        final newMsgs = List<Message>.of(state.messages, growable: true);
        for (int i = 0; i < calls.length && i < toolResults.length; i++) {
          final r = toolResults[i];
          final toolMsg = Message(
            content: r['content'] as String,
            role: 'tool',
            toolCallId: r['tool_call_id'] as String?,
            timestamp: DateTime.now(), conversationId: convId,
          );
          await _saveMsg(toolMsg);
          nextHistory.add(toolMsg);
          newMsgs.add(toolMsg);
        }
        state = state.copyWith(messages: newMsgs);

        _setState(AgentState.thinking);
        // Follow-up WITH tools — allow multi-step sequences like
        // list_installed_apps → open_app. maxIterations=8 prevents loops.
        final bool hasMoreIterations = iterations < maxIterations;
        if (!hasMoreIterations) break;
        result = await _api.chatWithTools(
          systemPrompt: await PromptBuilder.build(nextHistory, '',
              toolNames: registry.names, conversationId: convId),
          history: nextHistory, userMessage: '', tools: toolDefs,
        ).timeout(const Duration(seconds: 45));
      }

      var finalText = result.content.isNotEmpty ? result.content : '';
      finalText = ToolExecutor.stripToolCallsFromContent(finalText);
      // stripToolCallsFromContent already handles Chinese/English call patterns
      finalText = finalText.trim();

      // If model produced no text after tool execution, supply a minimal ack
      // so the user doesn't see silent nothing.
      if (finalText.isEmpty) {
        finalText = '好了。';
      }

      final aiMsg = Message(
        content: finalText, role: 'assistant',
        timestamp: DateTime.now(), conversationId: convId,
      );
      await db.insert('messages', aiMsg.toMap());
      await DB.touchConversation(convId);
      state = state.copyWith(messages: [...state.messages, aiMsg]);

      // Update tokens
      final allMsgs = state.messages;
      final prompt = await PromptBuilder.build(allMsgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final tokens = PromptBuilder.estimateTokens(prompt, allMsgs);

      _setState(AgentState.idle);
      state = state.copyWith(
        loading: false, streaming: '',
        tokenCount: tokens,
        contextRatio: state.contextLimit > 0 ? tokens / state.contextLimit : 0,
        clearSendTime: true,
      );
    } catch (e) {
      try {
        final prompt = await PromptBuilder.build(nextHistory, text,
            toolNames: ToolRegistry().names, conversationId: convId);
        _setState(AgentState.speaking);
        final reply = await _api.chatStream(
          systemPrompt: prompt, history: nextHistory, userMessage: text,
          onChunk: (c) {
            final b = StringBuffer(state.streaming);
            b.write(c);
            state = state.copyWith(streaming: b.toString());
          },
        ).timeout(const Duration(seconds: 10)); // short fallback — already waited 90s+ in tool path
        final aiMsg = Message(
          content: reply.isNotEmpty ? reply : '（请求超时，请重试）',
          role: 'assistant', timestamp: DateTime.now(), conversationId: convId,
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
          loading: false, streaming: '',
          tokenCount: tokens,
          contextRatio: state.contextLimit > 0 ? tokens / state.contextLimit : 0,
          clearSendTime: true,
        );
      } catch (e2) {
        _setState(AgentState.idle);
        state = state.copyWith(
          loading: false, streaming: '',
          error: '请求失败: ${e2.toString().length > 100 ? '${e2.toString().substring(0, 100)}…' : e2}',
          clearSendTime: true,
        );
      }
    }
  }

  Future<void> _saveMsg(Message msg) async {
    try {
      final db = await DB.database;
      await db.insert('messages', msg.toMap());
    } catch (_) {}
  }
}
