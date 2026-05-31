import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../theme/theme_provider.dart';
import '../services/database_service.dart';
import '../models/conversation.dart';
import '../commands/command_registry.dart';
import '../commands/command_executor.dart';
import 'chat_provider.dart';
import 'settings_screen.dart';
import 'agent_avatar.dart';
import 'thinking_overlay.dart';
import 'ui_controller.dart';
import 'webview_canvas.dart';

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
  final Map<int, int> _typewriterIdx = {};
  final Set<int> _expandedTools = {};
  int? _lastConvId;

  // Compiled-once regexes for _cleanDisplay
  static final _reToolCalls = RegExp(r'<tool_calls\b[^>]*>.*?</tool_calls>', dotAll: true);
  static final _reInvoke = RegExp(r'<invoke\s[^>]*>.*?</invoke>', dotAll: true);
  static final _reParameter = RegExp(r'<parameter\s[^>]*>.*?</parameter>', dotAll: true);
  static final _reXmlTags = RegExp(r'</?(?:tool_calls|invoke|parameter)\b[^>]*>', dotAll: true);

  @override
  void initState() {
    super.initState();
    _loadConversations();
  }

  @override
  void dispose() { _ctrl.dispose(); _scroll.dispose(); super.dispose(); }

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

  Future<void> _send() async {
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
    ref.read(chatProvider.notifier).send(t);
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
    // Watch only fields that should trigger a full rebuild.
    // Messages/loading/conversationId trigger rebuild; streaming/token/toolStatus do NOT.
    final messages = ref.watch(chatProvider.select((s) => s.messages));
    final loading = ref.watch(chatProvider.select((s) => s.loading));
    final conversationId = ref.watch(chatProvider.select((s) => s.conversationId));
    final error = ref.watch(chatProvider.select((s) => s.error));
    // Snapshot for everything else — no rebuild on these field changes
    final s = ref.read(chatProvider);
    final theme = ref.watch(themeProvider);
    final c = ThemeColors(theme);

    // Clear typewriter indices when conversation changes
    if (conversationId != _lastConvId) {
      _typewriterIdx.clear();
      _lastConvId = conversationId;
    }

    return Scaffold(
      backgroundColor: c.bgRoot,
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu, size: 22),
          color: c.textSecondary,
          onPressed: () => setState(() => _drawerOpen = !_drawerOpen),
        ),
        title: GestureDetector(
          onTap: () => setState(() => _drawerOpen = !_drawerOpen),
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
                const IgnorePointer(ignoring: false, child: WebViewCanvas()),
                _buildMessagesColumn(s, c),
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
        ThinkingOverlay(
          state: s.agentState,
          accentColor: c.accent,
          statusText: s.agentToolStatus.isNotEmpty ? s.agentToolStatus : null,
          sendStartedAt: s.sendStartedAt,
        ),
        if (_drawerOpen) _buildDrawer(s, c),
        Expanded(child: _buildMessages(s, c)),
        if (_showSuggestions) _buildSuggestions(c),
      ],
    );
  }

  // ═══════════════════════════════════════
  // CONTEXT BAR
  // ═══════════════════════════════════════

  Widget _buildContextBar(ChatState s, ThemeColors c) {
    final pct = (s.contextRatio * 100).clamp(0.0, 100.0);
    final color = pct > 95
        ? const Color(0xFFFF3B30)
        : pct > 80
            ? const Color(0xFFFF9500)
            : c.accent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(children: [
        // Token count
        Text(
          '${_fmtK(s.tokenCount)} / ${_fmtK(s.contextLimit)}',
          style: TextStyle(fontSize: 11, color: c.textTertiary, fontFamily: 'monospace'),
        ),
        const SizedBox(width: 8),
        // Progress bar
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: s.contextRatio.clamp(0.0, 1.0),
              backgroundColor: c.separator,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${pct.toStringAsFixed(0)}%',
          style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace'),
        ),
      ]),
    );
  }

  String _fmtK(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '$bytes B';
  }

  // ═══════════════════════════════════════
  // CONVERSATION DRAWER
  // ═══════════════════════════════════════

  Widget _buildDrawer(ChatState s, ThemeColors c) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(bottom: BorderSide(color: c.separator, width: 0.5)),
        boxShadow: c.shadowSm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // New conversation button
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final conv = await DB.createConversation();
                  await ref.read(chatProvider.notifier).switchConversation(conv.id!);
                  await _loadConversations();
                  setState(() => _drawerOpen = false);
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
          Divider(height: 1, color: c.separator),
          // Conversation list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
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
                    setState(() => _drawerOpen = false);
                  },
                );
              },
            ),
          ),
        ],
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
                        m.content.length > 300 ? '${m.content.substring(0, 300)}…' : m.content,
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
          return GestureDetector(
            onLongPress: () => _onBubbleLongPress(m, false),
            child: _bubble(text, false, c),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════
  // INPUT
  // ═══════════════════════════════════════

  // ═══════════════════════════════════════

  Widget _buildInput(ThemeColors c) {
    final chatState = ref.watch(chatProvider);
    return Container(
      padding: EdgeInsets.only(left: 16, right: 8, top: 10, bottom: MediaQuery.of(context).padding.bottom + 10),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.attach_file_rounded, size: 22),
          color: c.textSecondary,
          onPressed: _pickFile,
          tooltip: '上传文件',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: c.bgRoot, borderRadius: BorderRadius.circular(24)),
            child: TextField(
              controller: _ctrl,
              onChanged: _onTextChanged,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onSubmitted: (_) => _send(),
              style: TextStyle(fontSize: 15, color: c.textPrimary),
              decoration: InputDecoration(
                hintText: '输入 / 查看指令，或直接聊天...',
                hintStyle: TextStyle(color: c.textPlaceholder, fontSize: 15),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: chatState.loading
              ? IconButton(
                  key: const ValueKey('stop'),
                  icon: const Icon(Icons.stop_rounded, size: 24),
                  color: Colors.redAccent,
                  onPressed: () {
                    ref.read(chatProvider.notifier).cancel();
                  },
                  tooltip: '停止',
                )
              : IconButton(
                  key: const ValueKey('send'),
                  icon: Icon(_hasText ? Icons.send_rounded : Icons.mic_none_rounded, size: 24),
                  color: _hasText ? c.accent : c.textTertiary,
                  onPressed: _hasText ? _send : null,
                ),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════
  /// If typewriter mode is on, reveals assistant messages character by character.
  String _typewriterText(dynamic m, int idx) {
    final uic = UIController();
    if (!uic.typewriterMode || m.role == 'user' || m.role == 'tool') {
      return _cleanDisplay(m.content);
    }
    if (!_typewriterIdx.containsKey(idx)) _typewriterIdx[idx] = 0;
    final speed = uic.typewriterSpeed.clamp(5, 200);
    final target = m.content.length;
    final cur = _typewriterIdx[idx]!;
    if (cur < target) {
      final next = (cur + speed).clamp(0, target).toInt();
      _typewriterIdx[idx] = next;
      Future.delayed(const Duration(milliseconds: 30), () {
        if (mounted && _typewriterIdx[idx]! < target) setState(() {});
      });
      return _cleanDisplay(m.content.substring(0, next));
    }
    return _cleanDisplay(m.content);
  }

  Widget _bubble(String text, bool isUser, ThemeColors c) {
    final clean = _cleanDisplay(text);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AgentAvatar(size: 24, state: AgentState.idle),
            ),
          Flexible(
            child: Container(
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
              child: Text(clean, style: TextStyle(
                fontSize: 15, color: c.textPrimary, height: 1.5,
              )),
            ),
          ),
        ],
      ),
    );
  }

  /// Strip any residual XML tool-call markup from display text.
  /// Uses compiled-once static regexes — no recompilation per call.
  String _cleanDisplay(String text) {
    if (!text.contains('<')) return text;
    var c = text;
    c = c.replaceAll(_reToolCalls, '');
    c = c.replaceAll(_reInvoke, '');
    c = c.replaceAll(_reParameter, '');
    c = c.replaceAll(_reXmlTags, '');
    return c.trim();
  }
}
