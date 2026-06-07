import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../theme/theme_provider.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../models/conversation.dart';
import '../commands/command_registry.dart';
import '../commands/command_executor.dart';
import 'chat_provider.dart';
import 'settings_screen.dart';
import 'agent_avatar.dart';
import 'thinking_overlay.dart';
import 'ui_controller.dart';
import 'webview_canvas.dart';
import '../models/message.dart';
import '../services/tool_executor.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _hasText = false;
  List<CommandDef> _suggestions = [];
  bool _showSuggestions = false;
  List<Conversation> _conversations = [];
  bool _drawerOpen = false;
  int? _lastConvId;
  final Map<int, int> _typewriterIdx = {};
  final Set<int> _expandedTools = {};

  PushEvent? _pushEvent;
  StreamSubscription<PushEvent>? _pushSub;

  // Voice mode
  bool _voiceMode = false;
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _sttReady = false;
  bool _recording = false;
  String _voiceTranscript = '';
  final ValueNotifier<double> _voiceLevel = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _loadConversations();
    _pushSub = NotificationService().onPush.listen((event) {
      if (mounted) setState(() => _pushEvent = event);
    });
    _stt.initialize().then((ok) { if (mounted) setState(() => _sttReady = ok); });

    // Auto-scroll when message count increases (AI response arrives).
    // ConsumerState.ref may not be ready in initState — defer to first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.listen(chatProvider.select((s) => s.messages.length), (prev, next) {
        if (next > (prev ?? 0)) {
          if (mounted) _scrollDown();
        }
      });
      // Scroll to bottom when conversation changes
      ref.listen(chatProvider.select((s) => s.conversationId), (prev, next) {
        if (prev != next) {
          _expandedTools.clear();
          _typewriterIdx.clear();
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) _scrollDown();
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    _pushSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    _conversations = await DB.getConversations();
    if (mounted) setState(() {});
  }

  void _onTextChanged(String text) {
    setState(() {
      _hasText = text.trim().isNotEmpty;
      if (text.startsWith('/')) {
        _suggestions = CommandRegistry.suggest(text);
        _showSuggestions = _suggestions.isNotEmpty;
      } else {
        _showSuggestions = false;
        _suggestions = [];
      }
    });
  }

  Future<void> _send({bool isVoice = false}) async {
    final s = ref.read(chatProvider);
    if (s.loading) return;
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;

    final action = CommandRegistry.parse(t);
    if (action != null) {
      _ctrl.clear();
      setState(() { _hasText = false; _showSuggestions = false; });

      final result = await CommandExecutor.execute(action, ref);
      final convId = ref.read(chatProvider).conversationId;
      final db = await DB.database;
      await db.insert('messages', {
        'content': t, 'role': 'user', 'conversation_id': convId,
        'timestamp': DateTime.now().toIso8601String(), 'token_count': 0,
      });
      await db.insert('messages', {
        'content': result, 'role': 'assistant', 'conversation_id': convId,
        'timestamp': DateTime.now().toIso8601String(), 'token_count': 0,
      });
      await DB.touchConversation(convId);
      await ref.read(chatProvider.notifier).refreshFromDB();
      await _loadConversations();
      Future.delayed(const Duration(milliseconds: 100), _scrollDown);
      return;
    }

    _ctrl.clear();
    setState(() { _hasText = false; _showSuggestions = false; });
    ref.read(chatProvider.notifier).send(t, isVoice: isVoice);
    Future.delayed(const Duration(milliseconds: 100), _scrollDown);
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final src = File(file.path!);
      final size = file.size;

      // Copy to solvhen_files/ so agent can access it
      final appDir = await getApplicationDocumentsDirectory();
      final solvhenDir = Directory(p.join(appDir.path, 'solvhen_files'));
      if (!await solvhenDir.exists()) await solvhenDir.create(recursive: true);

      final dstPath = p.join(solvhenDir.path, file.name);
      await src.copy(dstPath);

      final sizeStr = size >= 1024 * 1024
          ? '${(size / (1024 * 1024)).toStringAsFixed(1)}MB'
          : size >= 1024 ? '${(size ~/ 1024)}KB' : '${size}B';

      final ext = p.extension(file.name).toLowerCase();
      const textExts = {
        '.txt', '.md', '.json', '.xml', '.csv', '.yaml', '.yml',
        '.dart', '.py', '.js', '.html', '.css', '.java', '.kt',
        '.swift', '.c', '.h', '.cpp', '.hpp', '.sh', '.bat',
        '.sql', '.log', '.cfg', '.ini', '.toml',
      };
      final isText = textExts.contains(ext);

      String msg;
      if (isText && size < 500 * 1024) {
        // Text file < 500KB — include content directly so LLM sees it immediately
        try {
          final content = await src.readAsString();
          msg = '上传了文件：${file.name} ($sizeStr)\n\n```$ext\n$content\n```';
        } catch (_) {
          msg = '上传了文件：${file.name} ($sizeStr)\n路径: solvhen_files/${file.name}\n（文件读取失败，可尝试用 read_file 工具）';
        }
      } else {
        msg = '上传了文件：${file.name} ($sizeStr)\n路径: solvhen_files/${file.name}';
      }

      // Auto-send — content goes directly to the LLM, not through the input field
      ref.read(chatProvider.notifier).send(msg);
      Future.delayed(const Duration(milliseconds: 100), _scrollDown);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件选择失败: $e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _applySuggestion(CommandDef cmd) {
    _ctrl.text = '/${cmd.name} ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() { _hasText = true; _showSuggestions = false; _suggestions = []; });
    FocusScope.of(context).requestFocus();
  }

  void _scrollDown() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _onBubbleLongPress(dynamic m, bool isUser) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('复制'),
            onTap: () {
              Navigator.pop(context);
              Clipboard.setData(ClipboardData(text: m.content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 1)),
              );
            },
          ),
          if (isUser) ...[
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(context);
                _ctrl.text = m.content;
                _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
                setState(() { _hasText = true; });
                FocusScope.of(context).requestFocus();
              },
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重新生成'),
              onTap: () {
                Navigator.pop(context);
                _regenerate();
              },
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _regenerate() async {
    final s = ref.read(chatProvider);
    if (s.loading) return;

    // Find last user message and delete everything after it
    final msgs = s.messages;
    int lastUserIdx = -1;
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role == 'user') { lastUserIdx = i; break; }
    }
    if (lastUserIdx < 0) return;

    final lastUserMsg = msgs[lastUserIdx];
    final keep = msgs.sublist(0, lastUserIdx);

    // Delete removed messages from DB
    final db = await DB.database;
    for (int i = lastUserIdx; i < msgs.length; i++) {
      if (msgs[i].id != null) {
        await db.delete('messages', where: 'id = ?', whereArgs: [msgs[i].id]);
      }
    }

    // Reset state to before the last user message
    ref.read(chatProvider.notifier).resetToMessages(keep);
    ref.read(chatProvider.notifier).send(lastUserMsg.content);
  }

  Future<void> _goSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    await _loadConversations();
    setState(() {});
  }

  // ═══════════════════════════════════════════════════
  // BUILD — Stack: gradient bg → DynamicBackground → Column → ParticleOverlay
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // Watch for rebuild triggers. Variables intentionally unused — the watch
    // itself registers rebuild dependencies; the read snapshot is in `s` below.
    ref.watch(chatProvider.select((s) => s.messages));
    ref.watch(chatProvider.select((s) => s.loading));
    final conversationId = ref.watch(chatProvider.select((s) => s.conversationId));
    ref.watch(chatProvider.select((s) => s.error));
    // Snapshot for everything else — no rebuild on these field changes
    final s = ref.read(chatProvider);
    final theme = ref.watch(themeProvider);
    final c = ThemeColors(theme);

    // Clear typewriter indices + scroll to bottom when conversation changes
    if (conversationId != _lastConvId) {
      _typewriterIdx.clear();
      _lastConvId = conversationId;
      // Scroll down after rebuild — new conversation may have messages
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollDown();
      });
    }

    return Scaffold(
      backgroundColor: c.bgRoot,
      extendBodyBehindAppBar: false,
      drawer: _buildDrawer(s, c),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu, size: 22),
          color: c.textSecondary,
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: GestureDetector(
          onTap: () => Scaffold.of(context).openDrawer(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AgentAvatar(
                key: ValueKey(s.agentState),
                size: 32,
                state: s.agentState,
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Solvhen', style: TextStyle(fontSize: 17)),
                  Text(
                    '对话 ${s.conversationId}',
                    style: TextStyle(fontSize: 11, color: c.textTertiary),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.mic_outlined, color: c.textSecondary, size: 22),
            onPressed: _toggleVoiceMode,
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: c.textSecondary, size: 22),
            onPressed: _goSettings,
          ),
        ],
      ),
      // WebView canvas behind messages. Background effects show through
      // transparent gaps between bubbles. PlatformView MUST stay in
      // an Expanded for tight constraints — Stack z-order is unreliable.
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                const IgnorePointer(child: WebViewCanvas()),
                _buildMessagesColumn(s, c),
                if (_pushEvent != null) _buildPushOverlay(c),
              ],
            ),
          ),
          // Input bar stays at bottom
          _buildInput(c),
        ],
      ),
    );
  }

  /// Messages + context bar floating on top of the WebView canvas.
  Widget _buildMessagesColumn(ChatState s, ThemeColors c) {
    return Column(
      children: [
        _buildContextBar(s, c),
        if (s.error != null && s.error!.isNotEmpty) _buildErrorBanner(s, c),
        ThinkingOverlay(
          state: s.agentState,
          accentColor: c.accent,
          statusText: s.agentToolStatus.isNotEmpty ? s.agentToolStatus : null,
          sendStartedAt: s.sendStartedAt,
        ),
        Expanded(child: _buildMessages(s, c)),
        if (_showSuggestions) _buildSuggestions(c),
      ],
    );
  }

  // ═══════════════════════════════════════
  // CONTEXT BAR
  // ═══════════════════════════════════════

  Widget _buildContextBar(ChatState s, ThemeColors c) {
    final hasApiData = s.apiPromptTokens > 0 || s.apiCompletionTokens > 0;
    final apiTotal = s.apiPromptTokens + s.apiCompletionTokens;
    final displayTokens = hasApiData ? apiTotal : s.tokenCount;
    final pct = s.contextRatio > 0
        ? (s.contextRatio * 100).clamp(0.0, 100.0)
        : (s.contextLimit > 0 ? (displayTokens / s.contextLimit * 100).clamp(0.0, 100.0) : 0.0);
    final barValue = s.contextRatio > 0
        ? s.contextRatio.clamp(0.0, 1.0)
        : (s.contextLimit > 0 ? (displayTokens / s.contextLimit).clamp(0.0, 1.0) : 0.0);
    final color = pct > 95
        ? c.danger
        : pct > 80
            ? c.warning
            : hasApiData ? c.success : c.accent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(children: [
        // Token count — API-real primary, estimate secondary
        Text(
          hasApiData
              ? 'API ${_fmtK(apiTotal)}'
              : '${_fmtK(s.tokenCount)} / ${_fmtK(s.contextLimit)}',
          style: TextStyle(fontSize: 11,
            color: hasApiData ? c.success : c.textTertiary,
            fontFamily: 'monospace',
            fontWeight: hasApiData ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (hasApiData) ...[
          const SizedBox(width: 4),
          Text(
            '(${_fmtK(s.tokenCount)}估)',
            style: TextStyle(fontSize: 9, color: c.textTertiary, fontFamily: 'monospace'),
          ),
        ],
        const SizedBox(width: 8),
        // Progress bar
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: barValue,
              backgroundColor: c.separator,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          hasApiData
              ? 'P:${_fmtK(s.apiPromptTokens)} C:${_fmtK(s.apiCompletionTokens)}'
              : '${pct.toStringAsFixed(0)}%',
          style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace'),
        ),
      ]),
    );
  }

  String _fmtK(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }

  // ═══════════════════════════════════════
  // ERROR BANNER
  // ═══════════════════════════════════════

  Widget _buildErrorBanner(ChatState s, ThemeColors c) {
    final msg = s.error ?? '';
    final isBalance = msg.contains('余额已用尽');
    final isRateLimit = msg.contains('太频繁');
    final bgColor = isBalance
        ? c.danger.withValues(alpha: 0.12)
        : isRateLimit
            ? c.warning.withValues(alpha: 0.12)
            : c.warning.withValues(alpha: 0.08);
    final borderColor = isBalance
        ? c.danger.withValues(alpha: 0.4)
        : c.warning.withValues(alpha: 0.3);
    final icon = isBalance ? Icons.account_balance_wallet_outlined
        : isRateLimit ? Icons.speed : Icons.warning_amber_outlined;
    final iconColor = isBalance ? c.danger : c.warning;

    return GestureDetector(
      onTap: () => ref.read(chatProvider.notifier).dismissError(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg, style: TextStyle(fontSize: 12, color: iconColor)),
          ),
          Text('点击关闭',
              style: TextStyle(fontSize: 11, color: c.textTertiary)),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════
  // PUSH OVERLAY
  // ═══════════════════════════════════════

  Widget _buildPushOverlay(ThemeColors c) {
    final event = _pushEvent!;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _pushEvent = null),
        child: Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {}, // absorb taps inside card
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: c.bgCardSolid,
                borderRadius: BorderRadius.circular(20),
                boxShadow: c.shadowSm,
                border: Border.all(color: c.accent.withValues(alpha: 0.2), width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Avatar + title
                  Row(children: [
                    const AgentAvatar(size: 40, state: AgentState.speaking),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(event.title,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(event.body,
                    style: TextStyle(fontSize: 14, color: c.textSecondary, height: 1.5)),
                  const SizedBox(height: 20),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: () => setState(() => _pushEvent = null),
                      child: Text('稍后', style: TextStyle(color: c.textTertiary)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        setState(() => _pushEvent = null);
                        // Focus on input for quick reply
                        _ctrl.clear();
                        setState(() { _hasText = false; _showSuggestions = false; });
                        FocusScope.of(context).requestFocus();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: c.accent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('回复'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  // CONVERSATION DRAWER
  // ═══════════════════════════════════════

  Widget _buildDrawer(ChatState s, ThemeColors c) {
    return Drawer(
      backgroundColor: c.bgRoot,
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Text('对话列表', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary)),
            ),
            // New conversation button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final conv = await DB.createConversation();
                    await ref.read(chatProvider.notifier).switchConversation(conv.id!);
                    await _loadConversations();
                    if (mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新对话'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.accent,
                    side: BorderSide(color: c.accent.withValues(alpha: 0.3)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: c.separator),
            // Conversation list
            Expanded(
              child: _conversations.isEmpty
                  ? Center(child: Text('暂无对话', style: TextStyle(color: c.textTertiary)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _conversations.length,
                      itemBuilder: (_, i) {
                final conv = _conversations[i];
                final isActive = conv.id == s.conversationId;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isActive ? Icons.chat_bubble : Icons.chat_bubble_outline,
                    size: 18,
                    color: isActive ? c.accent : c.textTertiary,
                  ),
                  title: Text(
                    conv.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive ? c.textPrimary : c.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${conv.messageCount} 条消息',
                    style: TextStyle(fontSize: 11, color: c.textTertiary),
                  ),
                  trailing: isActive
                      ? null
                      : IconButton(
                          icon: Icon(Icons.delete_outline, size: 16, color: c.textTertiary),
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('删除对话'),
                                content: Text('确定删除「${conv.title}」？消息不可恢复。'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );
                            if (confirm == true && conv.id != null) {
                              await DB.deleteConversation(conv.id!);
                              await _loadConversations();
                              if (conv.id == s.conversationId) {
                                // Switched to first available
                                final convs = await DB.getConversations();
                                if (convs.isNotEmpty) {
                                  await ref.read(chatProvider.notifier).switchConversation(convs.first.id!);
                                } else {
                                  final newConv = await DB.createConversation();
                                  await ref.read(chatProvider.notifier).switchConversation(newConv.id!);
                                }
                              }
                              setState(() {});
                            }
                          },
                        ),
                  onTap: () async {
                    if (conv.id != null && conv.id != s.conversationId) {
                      await ref.read(chatProvider.notifier).switchConversation(conv.id!);
                    }
                    Navigator.pop(context); // close drawer
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

// ═══════════════════════════════════════
  // MESSAGES
  // ═══════════════════════════════════════

  Widget _buildSuggestions(ThemeColors c) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: c.separator),
        itemBuilder: (_, i) {
          final cmd = _suggestions[i];
          return ListTile(
            dense: true,
            leading: Text('/${cmd.name}', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: c.accent, fontFamily: 'monospace',
            )),
            title: Text(cmd.description, style: TextStyle(fontSize: 13, color: c.textPrimary)),
            trailing: cmd.argsHint.isNotEmpty
                ? Text(cmd.argsHint, style: TextStyle(fontSize: 12, color: c.textTertiary))
                : null,
            onTap: () => _applySuggestion(cmd),
          );
        },
      ),
    );
  }

  Widget _buildMessages(ChatState s, ThemeColors c) {
    if (s.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AgentAvatar(size: 72, state: s.agentState),
            const SizedBox(height: 16),
            Text('开始对话', style: TextStyle(fontSize: 15, color: c.textSecondary)),
            const SizedBox(height: 4),
            Text('输入 / 查看可用指令',
                style: TextStyle(fontSize: 12, color: c.textPlaceholder)),
          ],
        ),
      );
    }
    
    // Find last assistant message with content (for avatar visibility)
    int lastAsstIdx = -1;
    for (int j = s.messages.length - 1; j >= 0; j--) {
      if (s.messages[j].role == 'assistant' && s.messages[j].content.isNotEmpty) {
        lastAsstIdx = j;
        break;
      }
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: s.messages.length + (s.loading ? 1 : 0),
        itemBuilder: (_, i) {
          if (i == s.messages.length) {
            // Loading indicator
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
                ),
                const SizedBox(width: 8),
                Text('Solvhen 思考中…', style: TextStyle(fontSize: 13, color: c.textTertiary)),
              ]),
            );
          }

          final m = s.messages[i];
          if (m.role == 'tool') {
            final isExpanded = _expandedTools.contains(i);
            return GestureDetector(
              onTap: () => setState(() {
                if (isExpanded) { _expandedTools.remove(i); } else { _expandedTools.add(i); }
              }),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: c.bgCardSolid,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 14, color: c.textTertiary),
                  const SizedBox(width: 6),
                  Text(m.toolCallId != null ? '工具调用完成' : '系统',
                    style: TextStyle(fontSize: 12, color: c.textTertiary)),
                  if (isExpanded) ...[
                    const Spacer(),
                    Expanded(
                      child: Text(
                        _cleanDisplay(m.content.length > 300 ? '${m.content.substring(0, 300)}…' : m.content),
                        style: TextStyle(fontSize: 11, color: c.textSecondary, fontFamily: 'monospace'),
                        maxLines: 8, overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ]),
              ),
            );
          }

          if (m.role == 'user') {
            return GestureDetector(
              onLongPress: () => _onBubbleLongPress(m, true),
              child: _bubble(m.content, true, c),
            );
          }

          // Assistant message with tool calls but empty content — compact indicator
          if (m.toolCallsJson != null && m.content.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.handyman_outlined, size: 13, color: c.textTertiary),
                const SizedBox(width: 6),
                Text('调用工具…', style: TextStyle(fontSize: 12, color: c.textTertiary)),
              ]),
            );
          }

          final text = _typewriterText(m, i);
          final isSpeaking = m.role == 'assistant' && ref.read(chatProvider).ttsSpeaking;
          return GestureDetector(
            onLongPress: () => _onBubbleLongPress(m, false),
            onTap: isSpeaking
                ? () => ref.read(chatProvider.notifier).stopSpeaking()
                : null,
            child: _bubble(text, false, c, showSpeaking: isSpeaking, showAvatar: false, avatarBelow: i == lastAsstIdx),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════
  // VOICE MODE
  // ═══════════════════════════════════════

  void _startVoice() async {
    debugPrint('[Solvhen] _startVoice: sttReady=$_sttReady recording=$_recording');
    if (!_sttReady) {
      setState(() => _voiceTranscript = '语音识别未就绪，请重试');
      return;
    }
    if (_recording) return;
    // Request RECORD_AUDIO explicitly (Xiaomi needs this)
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    if (!status.isGranted) {
      setState(() => _voiceTranscript = '请到系统设置中允许麦克风权限');
      return;
    }
    setState(() { _recording = true; _voiceTranscript = ''; });
    _stt.listen(
      onResult: (r) {
        final words = r.recognizedWords;
        setState(() => _voiceTranscript = words);
        if (r.finalResult && words.trim().isNotEmpty) {
          _stopVoice();
          _sendVoiceText(words);
        }
      },
      onSoundLevelChange: (l) => _voiceLevel.value = l / 10.0,
      listenMode: stt.ListenMode.dictation,
      localeId: 'zh_CN',
    );
  }

  void _stopVoice() {
    _stt.stop();
    setState(() => _recording = false);
    _voiceLevel.value = 0.0;
  }

  void _sendVoiceText(String text) {
    _ctrl.text = text;
    _send(isVoice: true);
  }

  void _toggleVoiceMode() {
    final s = ref.read(chatProvider);
    if (s.ttsSpeaking) {
      ref.read(chatProvider.notifier).stopSpeaking();
      return;
    }
    setState(() {
      _voiceMode = !_voiceMode;
      if (!_voiceMode) _stopVoice();
    });
  }

  // ═══════════════════════════════════════
  // INPUT
  // ═══════════════════════════════════════

  // ═══════════════════════════════════════

  Widget _buildInput(ThemeColors c) {
    final chatState = ref.watch(chatProvider);

    // Voice mode — large recording button
    if (_voiceMode) {
      return Container(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Toggle bar
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton.icon(
              onPressed: _toggleVoiceMode,
              icon: const Icon(Icons.keyboard, size: 18),
              label: const Text('键盘'),
              style: TextButton.styleFrom(foregroundColor: c.textTertiary),
            ),
          ]),
          const SizedBox(height: 8),
          // Transcript
          if (_voiceTranscript.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_voiceTranscript,
                style: TextStyle(fontSize: 16, color: c.textPrimary),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 16),
          // Mic button
          GestureDetector(
            onTap: _recording ? _stopVoice : _startVoice,
            child: ValueListenableBuilder<double>(
              valueListenable: _voiceLevel,
              builder: (_, level, __) {
                final scale = 1.0 + level * 0.3;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording
                          ? c.danger.withValues(alpha: 0.3)
                          : c.accent.withValues(alpha: 0.2),
                      border: Border.all(
                        color: _recording ? c.danger : c.accent,
                        width: 3,
                      ),
                      boxShadow: _recording ? [
                        BoxShadow(color: c.danger.withValues(alpha: 0.3), blurRadius: 24, spreadRadius: 2),
                      ] : null,
                    ),
                    child: Icon(
                      _recording ? Icons.stop_rounded : Icons.mic,
                      size: 36,
                      color: _recording ? c.danger : c.accent,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _recording ? '正在聆听... 说完点击停止' : '点击开始说话',
            style: TextStyle(fontSize: 13, color: c.textTertiary),
          ),
        ]),
      );
    }

    // Text mode — normal input
    return Container(
      padding: EdgeInsets.only(left: 12, right: 8, top: 8, bottom: MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(children: [
        // Left: + button (always)
        IconButton(
          icon: const Icon(Icons.add_rounded, size: 24),
          color: c.textSecondary,
          onPressed: _pickFile,
          tooltip: '上传文件',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        // Text field
        Expanded(
          child: TextField(
            controller: _ctrl,
            onChanged: _onTextChanged,
            maxLines: 6,
            maxLength: 4000,
            minLines: 1,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onSubmitted: (_) => _send(),
            style: TextStyle(fontSize: 15, color: c.textPrimary),
            decoration: InputDecoration(
              hintText: '消息...',
              hintStyle: TextStyle(color: c.textPlaceholder, fontSize: 15),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // Right: mic (empty) / send (has text) / stop (loading)
        if (chatState.loading)
          IconButton(
            icon: const Icon(Icons.stop_rounded, size: 24),
            color: Colors.redAccent,
            onPressed: () {
              ref.read(chatProvider.notifier).stopSpeaking();
              ref.read(chatProvider.notifier).cancel();
            },
          )
        else if (_hasText)
          IconButton(
            icon: const Icon(Icons.send_rounded, size: 22),
            color: c.accent,
            onPressed: _send,
          )
        else
          IconButton(
            icon: const Icon(Icons.mic_rounded, size: 24),
            color: c.textSecondary,
            onPressed: _toggleVoiceMode,
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════
  /// If typewriter mode is on, reveals assistant messages character by character.
  String _typewriterText(Message m, int idx) {
    final uic = UIController();
    if (!uic.typewriterMode || m.role == 'user' || m.role == 'tool') {
      return _cleanDisplay(m.content);
    }
    if (!_typewriterIdx.containsKey(idx)) _typewriterIdx[idx] = 0;
    final speed = uic.typewriterSpeed.clamp(5, 200);
    final target = m.content.length;
    final cur = _typewriterIdx[idx]!;
    if (cur < target) {
      // Advance cursor AFTER build frame, never mutate state during build.
      // This prevents frame-jitter from Flutter's multi-pass layout calling build().
      final next = (cur + speed).clamp(0, target).toInt();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _typewriterIdx[idx] = next;
        if (next < target) {
          Future.delayed(const Duration(milliseconds: 30), () {
            if (mounted) setState(() {});
          }).catchError((_) {});
        }
      });
      return _cleanDisplay(m.content.substring(0, next));
    }
    return _cleanDisplay(m.content);
  }

  Widget _bubble(String text, bool isUser, ThemeColors c, {bool showSpeaking = false, bool showAvatar = true, bool avatarBelow = false}) {
    final clean = _cleanDisplay(text);
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? (UIController().userBubbleColor ?? c.bubbleUser) : (UIController().bubbleColor ?? c.bubbleAssistant),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: isUser ? const Radius.circular(18) : const Radius.circular(4),
          bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(18),
        ),
      ),
      child: Text(clean, style: TextStyle(fontSize: 15, color: c.textPrimary, height: 1.5)),
    );

    // Avatar below bubble (Claude-style, last message only)
    if (avatarBelow && !isUser) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            bubble,
            if (showSpeaking) _buildSpeakingIndicator(c),
            const SizedBox(height: 6),
            AgentAvatar(size: 20, state: AgentState.idle),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser && showAvatar)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AgentAvatar(size: 24, state: AgentState.idle),
            ),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              bubble,
              if (showSpeaking) _buildSpeakingIndicator(c),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeakingIndicator(ThemeColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _SpeakingDot(delay: 0, color: c.accent),
        const SizedBox(width: 3),
        _SpeakingDot(delay: 200, color: c.accent),
        const SizedBox(width: 3),
        _SpeakingDot(delay: 400, color: c.accent),
        const SizedBox(width: 8),
        Text('点击停止', style: TextStyle(fontSize: 10, color: c.textTertiary)),
      ]),
    );
  }

  /// Strip any residual XML tool-call markup from display text.
  /// Delegates to ToolExecutor for unified stripping logic (same as API layer).
  String _cleanDisplay(String text) {
    if (!text.contains('<')) return text;
    return ToolExecutor.stripToolCallsFromContent(text);
  }
}

class _SpeakingDot extends StatefulWidget {
  final int delay;
  final Color color;
  const _SpeakingDot({required this.delay, required this.color});
  @override
  State<_SpeakingDot> createState() => _SpeakingDotState();
}

class _SpeakingDotState extends State<_SpeakingDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 4, height: 4,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.3 + _ctrl.value * 0.7),
        ),
      ),
    );
  }
}