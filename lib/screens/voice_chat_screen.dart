// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 语音聊天界面——实时语音对话模式的独立界面
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../theme/theme_provider.dart';
import '../services/voice_service.dart';
import '../services/api_service.dart';
import '../services/prompt_builder.dart';
import '../tools/tool_registry.dart';
import 'agent_avatar.dart';
import 'chat_provider.dart';

/// 语音聊天界面——实时语音对话模式
/// TTS仅在语音输入触发，文字输入静默
class VoiceChatScreen extends ConsumerStatefulWidget {
  const VoiceChatScreen({super.key});
  @override
  ConsumerState<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends ConsumerState<VoiceChatScreen>
    with SingleTickerProviderStateMixin {
  final VoiceService _voice = VoiceService();
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _recording = false;
  bool _processing = false;
  String _transcript = '';
  String _reply = '';
  bool _autoMode = false;
  late AnimationController _pulseCtrl;
  bool _sttReady = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _init();
  }

  Future<void> _init() async {
    await _voice.init();
    _sttReady = await _stt.initialize();
  }

  @override
  void dispose() {
    _stopListening();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _startListening() {
    if (_recording || _processing || !_sttReady) return;
    setState(() {
      _recording = true;
      _transcript = '';
      _reply = '';
    });

    _stt.listen(
      onResult: (r) {
        final words = r.recognizedWords;
        final isFinal = r.finalResult;
        setState(() {
          _transcript = words;
          if (isFinal && _autoMode) {
            _recording = false;
            _sendToLLM(words);
          }
        });
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        localeId: 'zh_CN',
      ),
    );
  }

  void _stopListening() {
    _stt.stop();
    setState(() => _recording = false);
  }

  void _onHoldRelease() {
    if (!_autoMode && _recording) {
      _stopListening();
      if (_transcript.trim().isNotEmpty) _sendToLLM(_transcript);
    }
  }

  Future<void> _sendToLLM(String text) async {
    setState(() => _processing = true);
    try {
      final s = ref.read(chatProvider);
      final registry = ToolRegistry();
      final prompt = await PromptBuilder.build(
        s.messages,
        text,
        toolNames: registry.names,
        conversationId: s.conversationId,
      );
      final api = ApiService();
      final result = await api
          .chatStream(
            systemPrompt: prompt,
            history: s.messages,
            userMessage: text,
          )
          .timeout(const Duration(seconds: 30));
      final reply = result.content.isNotEmpty ? result.content : '嗯，我在。';
      setState(() {
        _reply = reply;
        _processing = false;
      });
      await _voice.speak(reply);
    } catch (e) {
      setState(() {
        _reply = '抱歉，出了点问题: $e';
        _processing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final c = ThemeColors(theme);
    final pulse = _pulseCtrl;

    return Scaffold(
      backgroundColor: c.bgRoot,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: c.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        title:
            Text('语音对话', style: TextStyle(color: c.textPrimary, fontSize: 16)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('自动',
                  style: TextStyle(
                      fontSize: 12,
                      color: _autoMode ? c.accent : c.textTertiary)),
              Switch(
                value: _autoMode,
                onChanged: (v) => setState(() => _autoMode = v),
                activeThumbColor: c.accent,
              ),
            ]),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const Spacer(flex: 2),
          AnimatedBuilder(
            animation: pulse,
            builder: (_, __) {
              final scale = _recording ? 1.0 + pulse.value * 0.08 : 1.0;
              return Transform.scale(
                scale: scale,
                child: AgentAvatar(
                  size: 100,
                  state: _processing
                      ? AgentState.thinking
                      : _recording
                          ? AgentState.speaking
                          : AgentState.idle,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          if (_recording)
            Text('正在聆听...', style: TextStyle(fontSize: 14, color: c.accent))
          else if (_processing)
            Text('思考中...', style: TextStyle(fontSize: 14, color: c.accent))
          else
            Text(_autoMode ? '自动模式 — 对我说话' : '按住说话，松开发送',
                style: TextStyle(fontSize: 14, color: c.textTertiary)),
          const Spacer(),
          if (_transcript.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: c.bgCardSolid,
                  borderRadius: BorderRadius.circular(16)),
              child: Text(_transcript,
                  style: TextStyle(fontSize: 18, color: c.textPrimary)),
            ),
          if (_reply.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.accent.withValues(alpha: 0.2)),
              ),
              child: Text(_reply,
                  style: TextStyle(fontSize: 16, color: c.textPrimary)),
            ),
          const Spacer(),
          if (!_autoMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: GestureDetector(
                onLongPressStart: (_) => _startListening(),
                onLongPressEnd: (_) => _onHoldRelease(),
                onLongPressCancel: _stopListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _recording
                        ? c.danger.withValues(alpha: 0.3)
                        : c.accent.withValues(alpha: 0.15),
                    border: Border.all(
                        color: _recording ? c.danger : c.accent, width: 3),
                  ),
                  child: Icon(Icons.mic,
                      size: 36, color: _recording ? c.danger : c.accent),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
