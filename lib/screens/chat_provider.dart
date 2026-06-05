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
  final int apiPromptTokens;
  final int apiCompletionTokens;
  final AgentState agentState;
  final String agentToolStatus;
  final DateTime? sendStartedAt;
  final bool ttsSpeaking;         // TTS is currently playing

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
    int? apiPromptTokens,
    int? apiCompletionTokens,
    AgentState? agentState,
    String? agentToolStatus,
    DateTime? sendStartedAt,
    bool? ttsSpeaking,
    bool clearSendTime = false,
    bool clearErr = false,
  }) => ChatState(
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
    sendStartedAt: clearSendTime ? null : (sendStartedAt ?? this.sendStartedAt),
    ttsSpeaking: ttsSpeaking ?? this.ttsSpeaking,
  );
}

class ChatNotifier extends StateNotifier<ChatState> {
  final ApiService _api = ApiService();
  bool _historyReady = false;
  bool _interrupted = false;
  String _ttsBuf = '';  // buffer for sentence detection

  ChatNotifier(Ref ref) : super(const ChatState()) { _init(); }

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
      PromptBuilder.invalidateStableCache();
    } catch (_) {}
  }

  void _setState(AgentState s, [String? status]) {
    state = state.copyWith(agentState: s, agentToolStatus: status ?? '');
  }

  void cancel() {
    _interrupted = true;
    _setState(AgentState.idle);
  }

  void dismissError() {
    state = state.copyWith(clearErr: true);
  }

  /// Interrupt TTS playback.
  void stopSpeaking() {
    VoiceService().stop();
    state = state.copyWith(ttsSpeaking: false);
  }

  Future<void> push({required String title, required String body, String? payload}) async {
    await NotificationService().show(title: title, body: body, payload: payload);
  }

  // ═══════════════════════════════════════════════════
  // SEND
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

    final nextHistory = List<Message>.from(historyBefore)..add(userMsg);

    try {
      final registry = ToolRegistry();
      final toolDefs = registry.getToolDefs();

      var result = await _api.chatWithTools(
        systemPrompt: await PromptBuilder.build(historyBefore, text,
            toolNames: registry.names, conversationId: convId),
        history: historyBefore, userMessage: text, tools: toolDefs,
      ).timeout(const Duration(seconds: 90));

      int totalPromptTokens = result.usage?.promptTokens ?? 0;
      int totalCompletionTokens = result.usage?.completionTokens ?? 0;
      bool hadToolCalls = false;

      int iterations = 0;
      const maxIterations = 8;
      while (result.toolCalls != null &&
             result.toolCalls!.isNotEmpty &&
             iterations < maxIterations) {
        hadToolCalls = true;
        if (_interrupted) break;
        iterations++;
        final calls = result.toolCalls!;

        final cleanContent = ToolExecutor.stripToolCallsFromContent(result.content);
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

        _setState(ToolExecutor.stateForTool(calls.first.name), '执行中…');
        final executor = ToolExecutor(onStateChange: (s) => _setState(s));
        final toolResults = await executor.execute(calls);

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

        final midPrompt = await PromptBuilder.build(
            nextHistory, '', toolNames: registry.names, conversationId: convId);
        state = state.copyWith(
          tokenCount: PromptBuilder.estimateTokens(midPrompt, nextHistory),
          apiPromptTokens: totalPromptTokens,
          apiCompletionTokens: totalCompletionTokens,
          contextRatio: state.contextLimit > 0
              ? (totalPromptTokens + totalCompletionTokens) / state.contextLimit : 0,
        );

        _setState(AgentState.thinking);
        final bool hasMoreIterations = iterations < maxIterations;
        if (!hasMoreIterations) break;
        result = await _api.chatWithTools(
          systemPrompt: await PromptBuilder.build(nextHistory, '',
              toolNames: registry.names, conversationId: convId),
          history: nextHistory, userMessage: '', tools: toolDefs,
        ).timeout(const Duration(seconds: 45));

        if (result.usage != null) {
          totalPromptTokens += result.usage!.promptTokens;
          totalCompletionTokens += result.usage!.completionTokens;
        }
      }

      // Final reply via streaming for real-time display
      if (_interrupted) {
        _setState(AgentState.idle);
        state = state.copyWith(loading: false, streaming: '', clearSendTime: true);
        return;
      }

      _setState(AgentState.speaking);
      _ttsBuf = '';
      final voice = VoiceService();
      await voice.init();
      state = state.copyWith(ttsSpeaking: true);

      String finalText;
      try {
        final prompt = await PromptBuilder.build(nextHistory, '',
            toolNames: ToolRegistry().names, conversationId: convId);
        final streamResult = await _api.chatStream(
          systemPrompt: prompt, history: nextHistory, userMessage: '',
          onChunk: (chunk) {
            final sb = StringBuffer(state.streaming);
            sb.write(chunk);
            state = state.copyWith(streaming: sb.toString());
            _ttsBuf += chunk;
            _flushTtsSentences(voice);
          },
        ).timeout(const Duration(seconds: 60));
        finalText = streamResult.content;
      } catch (_) {
        // Fallback to non-streaming result
        finalText = result.content;
      }

      finalText = ToolExecutor.stripToolCallsFromContent(finalText);
      finalText = finalText.trim();
      if (finalText.isEmpty) finalText = '好了。';

      // Flush remaining TTS
      final remaining = _ttsBuf.trim();
      if (remaining.isNotEmpty && remaining.length > 1) {
        unawaited(voice.speakChunk(remaining));
      }

      final aiMsg = Message(
        content: finalText, role: 'assistant',
        timestamp: DateTime.now(), conversationId: convId,
      );
      await db.insert('messages', aiMsg.toMap());
      await DB.touchConversation(convId);

      // TTS will finish in background
      unawaited(Future.delayed(const Duration(seconds: 2)).then((_) {
        state = state.copyWith(ttsSpeaking: false);
      }));

      final allMsgs = [...state.messages, aiMsg];
      final newPrompt = await PromptBuilder.build(allMsgs, '',
          toolNames: ToolRegistry().names, conversationId: convId);
      final estimated = PromptBuilder.estimateTokens(newPrompt, allMsgs);

      _setState(AgentState.idle);
      state = state.copyWith(
        messages: [...state.messages, aiMsg],
        loading: false, streaming: '',
        tokenCount: estimated,
        apiPromptTokens: totalPromptTokens,
        apiCompletionTokens: totalCompletionTokens,
        contextRatio: state.contextLimit > 0
            ? (totalPromptTokens + totalCompletionTokens) / state.contextLimit : 0,
        clearSendTime: true,
      );
    } on ApiBalanceException catch (e) {
      _setState(AgentState.idle);
      state = state.copyWith(loading: false, streaming: '', error: e.message, clearSendTime: true);
    } on ApiRateLimitException catch (e) {
      _setState(AgentState.idle);
      state = state.copyWith(loading: false, streaming: '', error: e.message, clearSendTime: true);
    } on ApiAuthException catch (e) {
      _setState(AgentState.idle);
      state = state.copyWith(loading: false, streaming: '', error: e.message, clearSendTime: true);
    } catch (e) {
      // Fallback: non-streaming
      try {
        final prompt = await PromptBuilder.build(nextHistory, text,
            toolNames: ToolRegistry().names, conversationId: convId);
        _setState(AgentState.speaking);
        final streamResult = await _api.chatStream(
          systemPrompt: prompt, history: nextHistory, userMessage: text,
          onChunk: (c) {
            final b = StringBuffer(state.streaming);
            b.write(c);
            state = state.copyWith(streaming: b.toString());
          },
        ).timeout(const Duration(seconds: 10));
        final reply = streamResult.content;
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
      } on ApiBalanceException catch (e2) {
        _setState(AgentState.idle);
        state = state.copyWith(loading: false, streaming: '', error: e2.message, clearSendTime: true);
      } on ApiRateLimitException catch (e2) {
        _setState(AgentState.idle);
        state = state.copyWith(loading: false, streaming: '', error: e2.message, clearSendTime: true);
      } on ApiAuthException catch (e2) {
        _setState(AgentState.idle);
        state = state.copyWith(loading: false, streaming: '', error: e2.message, clearSendTime: true);
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

  /// Flush complete sentences from TTS buffer to voice service.
  void _flushTtsSentences(VoiceService voice) {
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

  Future<void> _saveMsg(Message msg) async {
    try {
      final db = await DB.database;
      await db.insert('messages', msg.toMap());
    } catch (_) {}
  }
}
