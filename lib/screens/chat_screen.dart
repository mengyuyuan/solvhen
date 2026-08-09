import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../models/conversation.dart';
import '../commands/command_registry.dart';
import '../commands/command_executor.dart';
import '../core/security/tool_security.dart';
import 'chat_provider.dart';
import 'settings_screen.dart';
import 'agent_avatar.dart';
import 'thinking_overlay.dart';
import 'ui_controller.dart';
import 'webview_canvas.dart';
import 'markdown_message.dart';
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
  final _inputFocus = FocusNode();
  bool _hasText = false;
  bool _inputFocused = false;
  List<CommandDef> _suggestions = [];
  bool _showSuggestions = false;
  List<Conversation> _conversations = [];
  int? _lastConvId;
  final Map<int, int> _typewriterIdx = {};
  final Set<int> _expandedTools = {};
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _streamScrollTimer;

  PushEvent? _pushEvent;
  StreamSubscription<PushEvent>? _pushSub;
  int? _pendingProactiveConvId; // 待切换的主动消息对话

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
    _inputFocus.addListener(() {
      if (mounted) setState(() => _inputFocused = _inputFocus.hasFocus);
    });
    _loadConversations();
    _pushSub = NotificationService().onPush.listen((event) {
      if (!mounted) return;
      try {
        final data = jsonDecode(event.payload ?? '{}');
        if (data['action'] == 'open_conv') {
          final convId = data['convId'] as int;
          _loadConversations();
          final s = ref.read(chatProvider);
          if (s.conversationId == convId) {
            ref.read(chatProvider.notifier).refreshFromDB();
          } else {
            // 延迟到下一帧切换，避免 build 期间修改状态
            _pendingProactiveConvId = convId;
            if (mounted) setState(() {});
          }
          return;
        }
      } catch (_) {}
      setState(() => _pushEvent = event);
    });
    _stt.initialize().then((ok) {
      if (mounted) setState(() => _sttReady = ok);
    });

    // Auto-scroll when message count increases (AI response arrives).
    // ConsumerState.ref may not be ready in initState — defer to first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.listen(chatProvider.select((s) => s.messages.length), (prev, next) {
        if (next > (prev ?? 0)) {
          if (mounted) _scrollDown();
        }
      });
      ref.listen(chatProvider.select((s) => s.streaming.length), (prev, next) {
        if (next > (prev ?? 0)) _scheduleStreamScroll();
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
    _inputFocus.dispose();
    _pushSub?.cancel();
    _streamScrollTimer?.cancel();
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
      setState(() {
        _hasText = false;
        _showSuggestions = false;
      });

      final result = await CommandExecutor.execute(
        action,
        ref,
        onApproval: _confirmSlashApproval,
      );
      final convId = ref.read(chatProvider).conversationId;
      final db = await DB.database;
      await db.insert('messages', {
        'content': t,
        'role': 'user',
        'conversation_id': convId,
        'timestamp': DateTime.now().toIso8601String(),
        'token_count': 0,
      });
      await db.insert('messages', {
        'content': result,
        'role': 'assistant',
        'conversation_id': convId,
        'timestamp': DateTime.now().toIso8601String(),
        'token_count': 0,
      });
      await DB.touchConversation(convId);
      await ref.read(chatProvider.notifier).refreshFromDB();
      await _loadConversations();
      Future.delayed(const Duration(milliseconds: 100), _scrollDown);
      return;
    }

    _ctrl.clear();
    setState(() {
      _hasText = false;
      _showSuggestions = false;
    });
    ref.read(chatProvider.notifier).send(t, isVoice: isVoice);
    Future.delayed(const Duration(milliseconds: 100), _scrollDown);
  }

  Future<bool> _confirmSlashApproval(ToolApprovalRequest request) async {
    if (!mounted) return false;
    final labels = <String, String>{
      'clear_conversation': '清除当前对话记录',
      'set_volume': '修改媒体音量',
      'set_brightness': '修改屏幕亮度',
      'toggle_wifi': '切换 WiFi',
      'toggle_bluetooth': '切换蓝牙',
      'set_ringer_mode': '修改响铃模式',
      'open_app': '打开其他应用',
    };
    final action = labels[request.toolName] ?? request.toolName;
    final details = request.arguments.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text('确认$action？'),
            content: Text(
              details.isEmpty
                  ? '这项操作会改变设备或本地数据。'
                  : '这项操作会改变设备或本地数据。\n\n$details',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认执行'),
              ),
            ],
          ),
        ) ??
        false;
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
          : size >= 1024
              ? '${(size ~/ 1024)}KB'
              : '${size}B';

      final ext = p.extension(file.name).toLowerCase();
      const textExts = {
        '.txt',
        '.md',
        '.json',
        '.xml',
        '.csv',
        '.yaml',
        '.yml',
        '.dart',
        '.py',
        '.js',
        '.html',
        '.css',
        '.java',
        '.kt',
        '.swift',
        '.c',
        '.h',
        '.cpp',
        '.hpp',
        '.sh',
        '.bat',
        '.sql',
        '.log',
        '.cfg',
        '.ini',
        '.toml',
      };
      final isText = textExts.contains(ext);

      String msg;
      if (isText && size < 500 * 1024) {
        // Text file < 500KB — include content directly so LLM sees it immediately
        try {
          final content = await src.readAsString();
          msg = '上传了文件：${file.name} ($sizeStr)\n\n```$ext\n$content\n```';
        } catch (_) {
          msg =
              '上传了文件：${file.name} ($sizeStr)\n路径: solvhen_files/${file.name}\n（文件读取失败，可尝试用 read_file 工具）';
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
          SnackBar(
              content: Text('文件选择失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _applySuggestion(CommandDef cmd) {
    _ctrl.text = '/${cmd.name} ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {
      _hasText = true;
      _showSuggestions = false;
      _suggestions = [];
    });
    FocusScope.of(context).requestFocus();
  }

  void _scrollDown() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _scheduleStreamScroll() {
    if (_streamScrollTimer?.isActive ?? false) return;
    _streamScrollTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted || !_scroll.hasClients) return;
      final distance =
          _scroll.position.maxScrollExtent - _scroll.position.pixels;
      // Do not drag the user back down after they intentionally scrolled up.
      if (distance <= 220) _scrollDown();
    });
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
                const SnackBar(
                    content: Text('已复制'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 1)),
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
                _ctrl.selection =
                    TextSelection.collapsed(offset: _ctrl.text.length);
                setState(() {
                  _hasText = true;
                });
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
      if (msgs[i].role == 'user') {
        lastUserIdx = i;
        break;
      }
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
    FocusManager.instance.primaryFocus?.unfocus();
    // render_html uses an Android PlatformView. Always unmount it before a
    // Navigator transition so MIUI cannot composite the stale surface above
    // the settings route (the same failure mode also caused input blackouts).
    await WebViewCanvasController().clearCanvas();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (!mounted) return;
    await _loadConversations();
    if (mounted) setState(() {});
  }

  Future<void> _openConversationDrawer() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await WebViewCanvasController().clearCanvas();
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) _scaffoldKey.currentState?.openDrawer();
  }

  // ═══════════════════════════════════════════════════
  // BUILD — Stack: gradient bg → DynamicBackground → Column → ParticleOverlay
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // 处理待切换的主动消息对话（延迟到 build 后的下一帧）
    if (_pendingProactiveConvId != null) {
      final pendingId = _pendingProactiveConvId!;
      _pendingProactiveConvId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(chatProvider.notifier).switchConversation(pendingId);
          _loadConversations();
        }
      });
    }

    // Watch for rebuild triggers. Variables intentionally unused — the watch
    // itself registers rebuild dependencies; the read snapshot is in `s` below.
    ref.watch(chatProvider.select((s) => s.messages));
    ref.watch(chatProvider.select((s) => s.loading));
    final conversationId =
        ref.watch(chatProvider.select((s) => s.conversationId));
    ref.watch(chatProvider.select((s) => s.error));
    ref.watch(chatProvider.select((s) => s.pendingApproval));
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
      key: _scaffoldKey,
      backgroundColor: c.bgRoot,
      extendBodyBehindAppBar: false,
      drawer: _buildDrawer(s, c),
      appBar: AppBar(
        toolbarHeight: 72,
        backgroundColor: c.bgCard.withValues(alpha: c.isDark ? 0.94 : 0.97),
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: c.separator, width: 0.8)),
        leadingWidth: 62,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            child: SolvhenIconSurface(
              colors: c,
              icon: Icons.menu_rounded,
              tooltip: '对话列表',
              onPressed: _openConversationDrawer,
            ),
          ),
        ),
        title: GestureDetector(
          onTap: _openConversationDrawer,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AgentAvatar(
                size: 32,
                state: s.agentState,
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Solvhen',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.25,
                    ),
                  ),
                  Text(
                    'LOCAL AGENT  /  #${s.conversationId.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 9,
                      color: c.textTertiary,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.65,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          SolvhenIconSurface(
            colors: c,
            icon: Icons.mic_none_rounded,
            tooltip: '语音模式',
            onPressed: _toggleVoiceMode,
          ),
          const SizedBox(width: 8),
          SolvhenIconSurface(
            colors: c,
            icon: Icons.tune_rounded,
            tooltip: '设置',
            onPressed: _goSettings,
          ),
          const SizedBox(width: 12),
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
                Positioned.fill(
                  child: ColoredBox(
                    color: c.bgRoot.withValues(alpha: c.isDark ? 0.82 : 0.87),
                  ),
                ),
                Positioned.fill(child: SolvhenDotField(color: c.dotColor)),
                _buildMessagesColumn(s, c),
                if (_pushEvent != null) _buildPushOverlay(c),
                if (s.pendingApproval != null) _buildToolApproval(s, c),
                if (s.pendingBudget != null) _buildBudgetApproval(s, c),
              ],
            ),
          ),
          // Input bar stays at bottom
          _buildInput(c),
        ],
      ),
    );
  }

  Widget _buildToolApproval(ChatState s, ThemeColors c) {
    final request = s.pendingApproval!;
    final args = const JsonEncoder.withIndent('  ').convert(request.arguments);
    final isDestructive = request.risk.name == 'destructive';
    final riskColor = isDestructive ? c.danger : c.warning;
    final riskLabel = switch (request.risk.name) {
      'read' => '只读操作',
      'modify' => '修改数据',
      'external' => '对外操作',
      'destructive' => '不可逆操作',
      _ => request.risk.name,
    };
    final originLabel = switch (request.context.origin.name) {
      'localUser' => '本地用户',
      'oneBot' => 'OneBot',
      'proactive' => '主动任务',
      'subAgent' => '子 Agent',
      'dynamicTool' => '动态工具',
      _ => request.context.origin.name,
    };
    return Positioned.fill(
      child: Material(
        color: c.scrim,
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              decoration: BoxDecoration(
                color: c.bgCard,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: riskColor.withValues(alpha: 0.38)),
                boxShadow: c.shadowGlass,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.separator,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: riskColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          isDestructive
                              ? Icons.gpp_maybe_outlined
                              : Icons.shield_outlined,
                          color: riskColor,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '需要你的确认',
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '未确认前，Solvhen 不会执行此操作',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    request.toolName,
                    style: TextStyle(
                      color: c.navy,
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SolvhenTag(
                        colors: c,
                        label: riskLabel,
                        color: riskColor,
                        icon: isDestructive
                            ? Icons.warning_amber_rounded
                            : Icons.tune_rounded,
                      ),
                      SolvhenTag(
                        colors: c,
                        label: originLabel,
                        color: c.accent,
                        icon: Icons.route_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '操作参数',
                    style: TextStyle(
                      color: c.textTertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: c.bgRoot,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: c.separator),
                        ),
                        child: Text(
                          args,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => ref
                            .read(chatProvider.notifier)
                            .resolveToolApproval(false),
                        child: const Text('拒绝'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => ref
                            .read(chatProvider.notifier)
                            .resolveToolApproval(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: riskColor,
                          foregroundColor: c.bgCard,
                        ),
                        child: const Text('仅本次允许'),
                      ),
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

  Widget _buildBudgetApproval(ChatState s, ThemeColors c) {
    final request = s.pendingBudget!;
    return Positioned.fill(
      child: Material(
        color: c.scrim,
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              decoration: BoxDecoration(
                color: c.bgCard,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: c.warning.withValues(alpha: 0.38)),
                boxShadow: c.shadowGlass,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.separator,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: c.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.speed_rounded,
                          color: c.warning,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '工具预算已暂停',
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '第 ${request.currentLoop}/${request.maxLoops} 轮已完成 '
                              '· ${request.usedIterations} 步',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SolvhenPanel(
                    colors: c,
                    showShadow: false,
                    backgroundColor: c.accentFaint,
                    child: Row(
                      children: [
                        _budgetMetric(c, '${request.currentLoop}', '当前循环'),
                        Icon(Icons.arrow_forward_rounded, color: c.accent),
                        _budgetMetric(c, '${request.proposedLoop}', '下一循环'),
                        Container(width: 1, height: 34, color: c.separator),
                        _budgetMetric(c, '${request.stepsPerLoop}', '每轮步数'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '继续会再开放 ${request.stepsPerLoop} 步，理论总上限 '
                    '${request.hardLimit} 步；运行时长以 Agent 运行设置为准。',
                    style: TextStyle(
                      color: c.textTertiary,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => ref
                              .read(chatProvider.notifier)
                              .resolveBudgetContinuation(false),
                          child: const Text('停止工具并总结'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => ref
                              .read(chatProvider.notifier)
                              .resolveBudgetContinuation(true),
                          style: FilledButton.styleFrom(
                            backgroundColor: c.warning,
                            foregroundColor: c.bgCard,
                          ),
                          child: Text(
                            '进入第 ${request.proposedLoop} 轮',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _budgetMetric(ThemeColors c, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: c.textPrimary,
              fontFamily: 'monospace',
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: c.textTertiary, fontSize: 9)),
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
          backgroundColor: c.accentFaint,
          borderColor: c.separator,
          textColor: c.navy,
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
        : (s.contextLimit > 0
            ? (displayTokens / s.contextLimit * 100).clamp(0.0, 100.0)
            : 0.0);
    final barValue = s.contextRatio > 0
        ? s.contextRatio.clamp(0.0, 1.0)
        : (s.contextLimit > 0
            ? (displayTokens / s.contextLimit).clamp(0.0, 1.0)
            : 0.0);
    final color = pct > 95
        ? c.danger
        : pct > 80
            ? c.warning
            : hasApiData
                ? c.success
                : c.accent;

    final detail = hasApiData
        ? 'P ${_fmtK(s.apiPromptTokens)}   C ${_fmtK(s.apiCompletionTokens)}'
        : '${_fmtK(s.tokenCount)} / ${_fmtK(s.contextLimit)} TOKENS';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SolvhenPanel(
        colors: c,
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        showShadow: false,
        backgroundColor: c.bgCard.withValues(alpha: c.isDark ? 0.88 : 0.92),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withValues(alpha: 0.16)),
                  ),
                  child: Icon(Icons.memory_rounded, size: 15, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CONTEXT WINDOW',
                        style: TextStyle(
                          fontSize: 9,
                          height: 1,
                          letterSpacing: 1.35,
                          fontWeight: FontWeight.w800,
                          color: c.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        detail,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1,
                          color: hasApiData ? c.success : c.textSecondary,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.35,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withValues(alpha: 0.18)),
                  ),
                  child: Text(
                    '${pct.toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 10,
                      color: color,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Stack(
              alignment: Alignment.centerLeft,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: barValue,
                    backgroundColor: c.separator.withValues(alpha: 0.72),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    minHeight: 4,
                  ),
                ),
                Positioned.fill(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(
                      7,
                      (_) => Container(
                        width: 1,
                        color: c.bgCard.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
    final icon = isBalance
        ? Icons.account_balance_wallet_outlined
        : isRateLimit
            ? Icons.speed
            : Icons.warning_amber_outlined;
    final iconColor = isBalance ? c.danger : c.warning;

    final canRestore = s.messages.any((message) => message.role == 'user');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            msg,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: iconColor),
          ),
        ),
        if (canRestore)
          TextButton(
            onPressed: _restoreLastInput,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              foregroundColor: iconColor,
            ),
            child: const Text('恢复输入', style: TextStyle(fontSize: 11)),
          ),
        IconButton(
          tooltip: '关闭错误提示',
          onPressed: () => ref.read(chatProvider.notifier).dismissError(),
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, size: 17, color: c.textTertiary),
        ),
      ]),
    );
  }

  void _restoreLastInput() {
    final messages = ref.read(chatProvider).messages;
    Message? lastUser;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].role == 'user') {
        lastUser = messages[index];
        break;
      }
    }
    if (lastUser == null) return;
    _ctrl.text = lastUser.content;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    ref.read(chatProvider.notifier).dismissError();
    _onTextChanged(_ctrl.text);
    _inputFocus.requestFocus();
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
          color: c.scrim,
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
                border: Border.all(
                    color: c.accent.withValues(alpha: 0.2), width: 1),
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
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: c.textPrimary)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(event.body,
                      style: TextStyle(
                          fontSize: 14, color: c.textSecondary, height: 1.5)),
                  const SizedBox(height: 20),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: () => setState(() => _pushEvent = null),
                      child:
                          Text('稍后', style: TextStyle(color: c.textTertiary)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        setState(() => _pushEvent = null);
                        // Focus on input for quick reply
                        _ctrl.clear();
                        setState(() {
                          _hasText = false;
                          _showSuggestions = false;
                        });
                        FocusScope.of(context).requestFocus();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: c.accent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
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
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: c.accent.withValues(alpha: 0.20),
                      ),
                    ),
                    child:
                        Icon(Icons.forum_outlined, size: 18, color: c.accent),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '对话空间',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'LOCAL THREAD INDEX',
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.success,
                      boxShadow: [
                        BoxShadow(
                          color: c.success.withValues(alpha: 0.28),
                          blurRadius: 7,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // New conversation button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    // Dispose any native render_html surface before the new
                    // conversation can receive focus and open the keyboard.
                    await WebViewCanvasController().clearCanvas();
                    await WidgetsBinding.instance.endOfFrame;
                    final conv = await DB.createConversation();
                    await ref
                        .read(chatProvider.notifier)
                        .switchConversation(conv.id!);
                    await _loadConversations();
                    if (mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新对话'),
                  style: FilledButton.styleFrom(
                    foregroundColor: c.isDark ? c.textPrimary : c.bgCard,
                    backgroundColor: c.accent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: c.separator),
            // Conversation list
            Expanded(
              child: _conversations.isEmpty
                  ? Center(
                      child:
                          Text('暂无对话', style: TextStyle(color: c.textTertiary)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _conversations.length,
                      itemBuilder: (_, i) {
                        final conv = _conversations[i];
                        final isActive = conv.id == s.conversationId;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          child: Material(
                            color:
                                isActive ? c.accentFaint : Colors.transparent,
                            borderRadius: BorderRadius.circular(15),
                            child: ListTile(
                              dense: true,
                              contentPadding:
                                  const EdgeInsets.fromLTRB(10, 4, 6, 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15),
                                side: BorderSide(
                                  color: isActive
                                      ? c.accent.withValues(alpha: 0.22)
                                      : Colors.transparent,
                                ),
                              ),
                              leading: Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? c.accentSoft
                                      : c.bgCard.withValues(alpha: 0.68),
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(color: c.separator),
                                ),
                                child: Text(
                                  '#${(conv.id ?? 0).toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: isActive ? c.accent : c.textTertiary,
                                  ),
                                ),
                              ),
                              title: Text(
                                conv.title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isActive
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isActive
                                      ? c.textPrimary
                                      : c.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${conv.messageCount.toString().padLeft(2, '0')} MESSAGES',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontFamily: 'monospace',
                                  letterSpacing: 0.4,
                                  color: c.textTertiary,
                                ),
                              ),
                              trailing: isActive
                                  ? Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: c.accent,
                                        shape: BoxShape.circle,
                                      ),
                                    )
                                  : IconButton(
                                      icon: Icon(Icons.delete_outline_rounded,
                                          size: 16, color: c.textTertiary),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (_) => AlertDialog(
                                            title: const Text('删除对话'),
                                            content: Text(
                                                '确定删除「${conv.title}」？消息不可恢复。'),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          context, false),
                                                  child: const Text('取消')),
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          context, true),
                                                  child: Text('删除',
                                                      style: TextStyle(
                                                          color: c.danger))),
                                            ],
                                          ),
                                        );
                                        if (confirm == true &&
                                            conv.id != null) {
                                          await DB.deleteConversation(conv.id!);
                                          await _loadConversations();
                                          if (conv.id == s.conversationId) {
                                            // Switched to first available
                                            final convs =
                                                await DB.getConversations();
                                            if (convs.isNotEmpty) {
                                              await ref
                                                  .read(chatProvider.notifier)
                                                  .switchConversation(
                                                      convs.first.id!);
                                            } else {
                                              final newConv =
                                                  await DB.createConversation();
                                              await ref
                                                  .read(chatProvider.notifier)
                                                  .switchConversation(
                                                      newConv.id!);
                                            }
                                          }
                                          setState(() {});
                                        }
                                      },
                                    ),
                              onTap: () async {
                                if (conv.id != null &&
                                    conv.id != s.conversationId) {
                                  await ref
                                      .read(chatProvider.notifier)
                                      .switchConversation(conv.id!);
                                }
                                if (!mounted) return;
                                Navigator.pop(context); // close drawer
                              },
                            ),
                          ),
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
            leading: Text('/${cmd.name}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.accent,
                  fontFamily: 'monospace',
                )),
            title: Text(cmd.description,
                style: TextStyle(fontSize: 13, color: c.textPrimary)),
            trailing: cmd.argsHint.isNotEmpty
                ? Text(cmd.argsHint,
                    style: TextStyle(fontSize: 12, color: c.textTertiary))
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SolvhenMatrixMark(colors: c),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: c.success.withValues(alpha: 0.20),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'SYSTEM READY',
                      style: TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.9,
                        color: c.success,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '想从哪里开始？',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '直接描述任务，或输入 / 打开能力指令',
                style: TextStyle(fontSize: 12, color: c.textTertiary),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _quickPromptChip('整理今天', Icons.auto_awesome_outlined, c),
                  _quickPromptChip('查看设备', Icons.devices_outlined, c),
                  _quickPromptChip('搜索网络', Icons.travel_explore, c),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Find last assistant message with content (for avatar visibility)
    int lastAsstIdx = -1;
    for (int j = s.messages.length - 1; j >= 0; j--) {
      if (s.messages[j].role == 'assistant' &&
          s.messages[j].content.isNotEmpty) {
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
            final streaming = _cleanDisplay(s.streaming).trim();
            if (streaming.isNotEmpty) {
              return _bubble(
                streaming,
                false,
                c,
                showAvatar: false,
                renderMarkdown: false,
              );
            }
            // Loading indicator
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Row(children: [
                AgentAvatar(size: 22, state: s.agentState),
                const SizedBox(width: 9),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.accentFaint,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: c.accent.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.6, color: c.accent),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'RUNNING / ${s.agentToolStatus.isEmpty ? '处理中' : s.agentToolStatus}',
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            );
          }

          final m = s.messages[i];
          if (m.role == 'tool') {
            final isExpanded = _expandedTools.contains(i);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() {
                    if (isExpanded) {
                      _expandedTools.remove(i);
                    } else {
                      _expandedTools.add(i);
                    }
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: c.bgCard.withValues(alpha: 0.90),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: c.success.withValues(alpha: 0.18),
                      ),
                      boxShadow: c.shadowCard,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c.success.withValues(alpha: 0.11),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: c.success.withValues(alpha: 0.16),
                                ),
                              ),
                              child: Icon(
                                m.toolCallId != null
                                    ? Icons.check_rounded
                                    : Icons.terminal_rounded,
                                size: 16,
                                color: c.success,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.toolCallId != null
                                        ? 'TOOL RESULT'
                                        : 'SYSTEM EVENT',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: c.success,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    m.toolCallId != null ? '工具调用完成' : '系统事件',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: c.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              isExpanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: c.textTertiary,
                            ),
                          ],
                        ),
                        if (isExpanded) ...[
                          const SizedBox(height: 9),
                          Divider(height: 1, color: c.separator),
                          const SizedBox(height: 9),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: c.bgRoot.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(
                                color: c.separator.withValues(alpha: 0.78),
                              ),
                            ),
                            child: Text(
                              _cleanDisplay(
                                m.content.length > 600
                                    ? '${m.content.substring(0, 600)}…'
                                    : m.content,
                              ),
                              style: TextStyle(
                                fontSize: 10,
                                color: c.textSecondary,
                                fontFamily: 'monospace',
                                height: 1.5,
                              ),
                              maxLines: 12,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
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
                Text('调用工具…',
                    style: TextStyle(fontSize: 12, color: c.textTertiary)),
              ]),
            );
          }

          final text = _typewriterText(m, i);
          final isSpeaking =
              m.role == 'assistant' && ref.read(chatProvider).ttsSpeaking;
          return GestureDetector(
            onLongPress: () => _onBubbleLongPress(m, false),
            onTap: isSpeaking
                ? () => ref.read(chatProvider.notifier).stopSpeaking()
                : null,
            child: _bubble(text, false, c,
                showSpeaking: isSpeaking,
                showAvatar: false,
                avatarBelow: i == lastAsstIdx,
                renderMarkdown: text == _cleanDisplay(m.content)),
          );
        },
      ),
    );
  }

  Widget _quickPromptChip(String label, IconData icon, ThemeColors c) {
    return Material(
      color: c.bgCard.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _ctrl.text = label;
          _ctrl.selection = TextSelection.collapsed(offset: label.length);
          _onTextChanged(label);
          _inputFocus.requestFocus();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.separator),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  // VOICE MODE
  // ═══════════════════════════════════════

  void _startVoice() async {
    debugPrint(
        '[Solvhen] _startVoice: sttReady=$_sttReady recording=$_recording');
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
    setState(() {
      _recording = true;
      _voiceTranscript = '';
    });
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
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        localeId: 'zh_CN',
      ),
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
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
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
              child: Text(
                _voiceTranscript,
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
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording
                          ? c.danger.withValues(alpha: 0.3)
                          : c.accent.withValues(alpha: 0.2),
                      border: Border.all(
                        color: _recording ? c.danger : c.accent,
                        width: 3,
                      ),
                      boxShadow: _recording
                          ? [
                              BoxShadow(
                                  color: c.danger.withValues(alpha: 0.3),
                                  blurRadius: 24,
                                  spreadRadius: 2),
                            ]
                          : null,
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
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        MediaQuery.of(context).padding.bottom + 9,
      ),
      decoration: BoxDecoration(
        color: c.bgCard.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: c.bgRoot.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _inputFocused
                    ? c.accent.withValues(alpha: 0.72)
                    : c.separator,
                width: _inputFocused ? 1.2 : 0.8,
              ),
              boxShadow: _inputFocused
                  ? [
                      BoxShadow(
                        color: c.accent.withValues(alpha: 0.10),
                        blurRadius: 18,
                        spreadRadius: -2,
                      ),
                    ]
                  : c.shadowSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 5, bottom: 5),
                  child: IconButton(
                    icon: const Icon(Icons.add_rounded, size: 21),
                    color: c.textSecondary,
                    onPressed: _pickFile,
                    tooltip: '上传文件',
                    style: IconButton.styleFrom(
                      backgroundColor: c.bgCard.withValues(alpha: 0.78),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _inputFocus,
                    onChanged: _onTextChanged,
                    maxLines: 6,
                    maxLength: 4000,
                    minLines: 1,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    onSubmitted: (_) => _send(),
                    style: TextStyle(fontSize: 15, color: c.textPrimary),
                    decoration: InputDecoration(
                      hintText: '输入消息或 / 指令',
                      hintStyle: TextStyle(
                        color: c.textPlaceholder,
                        fontSize: 14,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      fillColor: Colors.transparent,
                      filled: true,
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                if (chatState.loading)
                  Padding(
                    padding: const EdgeInsets.only(right: 5, bottom: 5),
                    child: IconButton.filled(
                      icon: const Icon(Icons.stop_rounded, size: 19),
                      color: c.bgCard,
                      style: IconButton.styleFrom(
                        backgroundColor: c.danger,
                        minimumSize: const Size(36, 36),
                      ),
                      onPressed: () {
                        ref.read(chatProvider.notifier).stopSpeaking();
                        ref.read(chatProvider.notifier).cancel();
                      },
                    ),
                  )
                else if (_hasText)
                  Padding(
                    padding: const EdgeInsets.only(right: 5, bottom: 5),
                    child: IconButton.filled(
                      icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      color: c.bgCard,
                      style: IconButton.styleFrom(
                        backgroundColor: c.accent,
                        minimumSize: const Size(36, 36),
                      ),
                      onPressed: _send,
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.mic_none_rounded, size: 23),
                    color: c.textSecondary,
                    onPressed: _toggleVoiceMode,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 12, color: c.success),
              const SizedBox(width: 5),
              Text(
                'LOCAL-FIRST',
                style: TextStyle(
                  fontSize: 9,
                  color: c.textTertiary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.45,
                ),
              ),
              const Spacer(),
              Text(
                'BYOK · NO TELEMETRY',
                style: TextStyle(
                  fontSize: 9,
                  color: c.textPlaceholder,
                  fontFamily: 'monospace',
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
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

  Widget _bubble(String text, bool isUser, ThemeColors c,
      {bool showSpeaking = false,
      bool showAvatar = true,
      bool avatarBelow = false,
      bool renderMarkdown = false}) {
    final clean = _cleanDisplay(text);
    final bubble = Container(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isUser
            ? (UIController().userBubbleColor ?? c.bubbleUser)
            : (UIController().bubbleColor ?? c.bubbleAssistant),
        border: Border.all(
          color: isUser
              ? c.accent.withValues(alpha: 0.24)
              : c.glassBorder.withValues(alpha: 0.92),
          width: 0.8,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(isUser ? 18 : 6),
          topRight: Radius.circular(isUser ? 6 : 18),
          bottomLeft:
              isUser ? const Radius.circular(18) : const Radius.circular(4),
          bottomRight:
              isUser ? const Radius.circular(4) : const Radius.circular(18),
        ),
        boxShadow: isUser ? null : c.shadowSm,
      ),
      child: renderMarkdown && !isUser
          ? SolvhenMarkdownMessage(
              data: clean,
              colors: c,
              onOpenLink: _openMarkdownLink,
            )
          : Text(
              clean,
              style: TextStyle(
                fontSize: 15,
                color: c.textPrimary,
                height: 1.5,
              ),
            ),
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
            const AgentAvatar(size: 20, state: AgentState.idle),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser && showAvatar)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: AgentAvatar(size: 24, state: AgentState.idle),
            ),
          Flexible(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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

  Future<void> _openMarkdownLink(Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法打开这个链接'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Strip any residual XML tool-call markup from display text.
  /// Delegates to ToolExecutor for unified stripping logic (same as API layer).
  String _cleanDisplay(String text) {
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

class _SpeakingDotState extends State<_SpeakingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.3 + _ctrl.value * 0.7),
        ),
      ),
    );
  }
}
