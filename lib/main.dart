import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/chat_screen.dart';
import 'theme/theme_provider.dart';
import 'services/notification_service.dart';
import 'services/voice_service.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final regFns = [
    registerThemeTools, registerSystemTools, registerFileTools,
    registerCodeTool, registerWebTools, registerWebExtractTool,
    registerHistoryTool, registerMemoryTools, registerUITools,
    registerDelegateTools,
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
  }

  @override
  void dispose() {
    _theme.removeListener(_onThemeChange);
    super.dispose();
  }

  void _onThemeChange() {
    if (mounted) setState(() {});
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
