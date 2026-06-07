// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 应用入口——初始化工具注册、主题、通知、语音服务、OneBot桥接，启动MaterialApp
// ═══════════════════════════════════════════════════════════════

library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/chat_screen.dart';
import 'theme/theme_provider.dart';
import 'services/notification_service.dart';
import 'services/voice_service.dart';
import 'services/onebot_bridge.dart';
import 'services/proactive_service.dart';
import 'services/api_service.dart';
import 'services/database_service.dart';
import 'services/tool_executor.dart';
import 'models/message.dart';
import 'tools/tool_registry.dart';
import 'tools/tools_theme.dart';
import 'tools/tools_system.dart';
import 'tools/tools_file.dart';
import 'tools/tools_code.dart';
import 'tools/tools_web.dart';
import 'tools/tools_web_extract.dart';
import 'tools/tools_history.dart';
import 'tools/tools_memory.dart';
import 'tools/tools_ui.dart';
import 'tools/tools_delegate.dart';
import 'tools/tools_model.dart';
import 'tools/tools_proactive.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final regFns = [
    registerThemeTools, registerSystemTools, registerFileTools,
    registerCodeTool, registerWebTools, registerWebExtractTool,
    registerHistoryTool, registerMemoryTools, registerUITools,
    registerDelegateTools, registerModelTools, registerDynamicTools,
    registerOneBotTools,
    registerProactiveTools,
  ];
  for (final fn in regFns) {
    try { fn(); } catch (_) { /* one tool broken shouldn't kill the app */ }
  }
  runApp(const ProviderScope(child: CompanionApp()));
}

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key});
  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp> {
  final _theme = ThemeNotifier();

  @override
  void initState() {
    super.initState();
    _theme.addListener(_onThemeChange);
    _theme.loadFromDB();
    NotificationService().init();
    VoiceService().init();
    _initOneBot();
    ProactiveService().start(); // 启动主动消息定时器
  }

  @override
  void dispose() {
    _theme.removeListener(_onThemeChange);
    super.dispose();
  }

  void _onThemeChange() {
    if (mounted) setState(() {});
  }

  /// 初始化 OneBot WebSocket 桥接——接收 QQ/微信消息
  Future<void> _initOneBot() async {
    try {
      final cfg = await DB.getConfig();
      final enabled = cfg['onebot_enabled'] ?? 'false';
      if (enabled != 'true') return;

      final portStr = cfg['onebot_port'] ?? '13579';
      final port = int.tryParse(portStr) ?? 13579;

      final bridge = OneBotBridge();
      bridge.onMessage = _handleOneBotMessage;
      await bridge.start(port: port);
    } catch (_) {}
  }

  /// 收到 OneBot 消息 → 调 AI → 回复
  Future<void> _handleOneBotMessage(OneBotMessage msg, String platform) async {
    try {
      final api = ApiService();
      ToolRegistry(); // Ensure tools are registered

      // 构建轻量历史（只取最近几条）
      final rows = await DB.getMessages(1, limit: 5);
      final history = rows.map((r) => Message.fromMap(r)).toList();

      final prompt = '你是 Solvhen，正在通过$platform帮用户回复消息。'
          '收到来自${msg.senderNickname ?? msg.userId.toString()}的消息：「${msg.rawMessage}」'
          '请用简短自然的口语回复，像真人聊天一样。直接回复内容，不要带引号或前缀。';

      final streamResult = await api.chatStream(
        systemPrompt: prompt,
        history: history,
        userMessage: msg.rawMessage,
      ).timeout(const Duration(seconds: 30));

      final reply = ToolExecutor.stripToolCallsFromContent(
          streamResult.content).trim();
      if (reply.isNotEmpty) {
        await OneBotBridge().sendReply(
          messageType: msg.messageType,
          userId: msg.userId,
          groupId: msg.groupId,
          message: reply,
        );
      }
    } catch (e) {
      debugPrint('[OneBot] reply error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solvhen',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(_theme.state),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
      home: const ChatScreen(),
    );
  }
}
