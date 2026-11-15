// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 应用入口——初始化工具注册、主题、通知、语音服务、OneBot桥接，启动MaterialApp
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/chat_screen.dart';
import 'screens/app_launch_gate.dart';
import 'theme/theme_provider.dart';
import 'services/notification_service.dart';
import 'services/voice_service.dart';
import 'services/onebot_bridge.dart';
import 'services/proactive_service.dart';
import 'services/update_service.dart';
import 'services/api_service.dart';
import 'services/database_service.dart';
import 'services/tool_executor.dart';
import 'core/llm/llm_config_store.dart';
import 'core/security/tool_security.dart';
import 'core/security/onebot_credentials.dart';
import 'core/security/developer_mode.dart';
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
import 'tools/tools_device.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeProactiveScheduling();
  } catch (error) {
    debugPrint(
        '[Proactive] scheduler initialization failed: ${error.runtimeType}');
  }
  final regFns = [
    registerThemeTools,
    registerSystemTools,
    registerDeviceTools,
    registerFileTools,
    registerCodeTool,
    registerWebTools,
    registerWebExtractTool,
    registerHistoryTool,
    registerMemoryTools,
    registerUITools,
    registerDelegateTools,
    registerModelTools,
    registerDynamicTools,
    registerOneBotTools,
    registerProactiveTools,
  ];
  for (final fn in regFns) {
    try {
      fn();
    } catch (_) {/* one tool broken shouldn't kill the app */}
  }
  runApp(const ProviderScope(child: CompanionApp()));
}

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key});
  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp>
    with WidgetsBindingObserver {
  final _theme = ThemeNotifier();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _theme.addListener(_onThemeChange);
    _theme.loadFromDB();
    _initAsync(); // Fire-and-forget async startup
  }

  Future<void> _initAsync() async {
    await NotificationService().init();
    VoiceService().init();
    SecuritySession.instance.reset();
    SecuritySession.instance.hydratePermissions(await DB.getToolPermissions());
    await LlmConfigStore().migrateLegacySecrets();
    await DB.purgeExpiredToolAudits();
    _initOneBot();
    final cfg = await DB.getConfig();
    DeveloperModeSession.instance.hydrate(cfg['developer_mode'] == 'true');
    // 首次或版本变更时写入 version_code
    final storedVersion = int.tryParse(cfg['version_code'] ?? '0') ?? 0;
    if (storedVersion < 5) {
      await DB.setConfig('version_code', '5');
    }
    if (cfg['proactive_enabled'] == 'true') {
      final mins = int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30;
      await startProactive(intervalMinutes: mins, sendImmediately: false);
    }

    // 只有用户明确配置了固定官方 HTTPS 地址才在启动时检查。
    // 旧版临时隧道地址会被保留在数据库中，但绝不会自动访问。
    final updateUrl = normalizeOfficialUpdateBaseUrl(cfg['update_url']);
    if (updateUrl != null) {
      try {
        final info = await checkForUpdate(
          updateUrl: updateUrl,
          currentVersionCode: 5,
        );
        if (info != null) {
          debugPrint('[Update] new version available: ${info.version}');
        }
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _theme.removeListener(_onThemeChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(setProactiveAppForeground(
      state == AppLifecycleState.resumed,
    ));
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
      final allowInsecure = cfg['onebot_allow_insecure_lan'] == 'true';
      final token = await OneBotCredentials().loadOrCreateToken();

      final bridge = OneBotBridge();
      bridge.onMessage = _handleOneBotMessage;
      await bridge.start(
        port: port,
        accessToken: token,
        allowInsecureLan: allowInsecure,
      );
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

      final streamResult = await api
          .chatStream(
            systemPrompt: prompt,
            history: history,
            userMessage: msg.rawMessage,
          )
          .timeout(const Duration(seconds: 30));

      final reply =
          ToolExecutor.stripToolCallsFromContent(streamResult.content).trim();
      if (reply.isNotEmpty) {
        await OneBotBridge().sendReply(
          messageType: msg.messageType,
          userId: msg.userId,
          groupId: msg.groupId,
          message: reply,
          sourceMessageId: msg.messageId,
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
      home: const AppLaunchGate(child: ChatScreen()),
    );
  }
}
