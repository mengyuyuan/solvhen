// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — flutter_background_service 前台Service，杀不死
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

const _channelId = 'solvhen_proactive';
const _notifId = 999;
const _bgServiceKey = 'solvhen_bg';

// ═══════════════════════════════════════
// 后台入口 —— @pragma 标记防止 tree-shaking
// ═══════════════════════════════════════

@pragma('vm:entry-point')
Future<bool> onBackgroundStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init DB + notification in background isolate
  await NotificationService().init();
  await DB.database; // warmup — ensure DB is ready

  Timer? _tickTimer;
  bool _ticking = false;

  // Load interval from config
  Future<int> _loadInterval() async {
    final cfg = await DB.getConfig();
    return (int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30).clamp(1, 1440);
  }

  // The tick logic — same as before but runs in background
  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final now = DateTime.now();

      final cfg = await DB.getConfig();
      if (cfg['proactive_enabled'] != 'true') {
        debugPrint('[BG-Proactive] disabled, skipping');
        return;
      }

      // Conflict: skip if user active in last 5 min
      final lastActivity = cfg['last_activity_at'];
      if (lastActivity != null) {
        final lastTime = DateTime.tryParse(lastActivity);
        if (lastTime != null && now.difference(lastTime).inMinutes < 5) {
          debugPrint('[BG-Proactive] skipped — user active');
          return;
        }
      }

      final api = ApiService();

      // Load personality from assets
      final personality = await _loadPersonality();
      final memText = await _loadMemories();
      final chatText = await _loadRecentChat();

      final prompt = '''
$personality

[系统指令：现在是主动消息模式]
你正在后台定时联系用户，这是你主动发起的。
当前时间：${now.hour}:${now.minute.toString().padLeft(2, '0')}

关于对方你知道：
$memText

最近对话：
$chatText

请用你的人格说一句自然的话联系对方。控制在20字以内。22点后回复[SKIP]。''';

      final result = await api.chatStream(
        systemPrompt: prompt, history: const [], userMessage: '（后台定时联系，请简短回复）',
      ).timeout(const Duration(seconds: 20));

      final text = ToolExecutor.stripToolCallsFromContent(result.content).trim();
      if (text.isEmpty || text == '[SKIP]') return;

      final convId = await _getActiveConvId();
      await _saveMessage(convId, text);

      await NotificationService().show(
        title: 'Solvhen',
        body: text,
        payload: jsonEncode({'action': 'open_conv', 'convId': convId}),
      );

      debugPrint('[BG-Proactive] sent: $text -> conv $convId');
    } catch (e) {
      debugPrint('[BG-Proactive] tick error: $e');
    } finally {
      _ticking = false;
    }
  }

  // Schedule tick with current interval
  void _scheduleTick(int minutes) {
    _tickTimer?.cancel();
    _tickTimer = Timer(Duration(minutes: minutes), () async {
      await _tick();
      final m = await _loadInterval();
      _scheduleTick(m);
    });
  }

  // Listen for interval changes from main isolate
  service.on('setInterval').listen((event) {
    final m = (event?['interval'] as int?)?.clamp(1, 1440) ?? 30;
    debugPrint('[BG-Proactive] interval changed to ${m}min');
    _scheduleTick(m);
  });

  // Start the tick loop
  final initialInterval = await _loadInterval();
  _scheduleTick(initialInterval);
  // First tick immediately
  await _tick();

  debugPrint('[BG-Proactive] service started, interval=${initialInterval}min');
  return true; // keep service alive
}

// ═══════════════════════════════════════
// Public API — called from main isolate
// ═══════════════════════════════════════

/// Start proactive messaging via background service.
Future<void> startProactive({required int intervalMinutes}) async {
  final clamped = intervalMinutes.clamp(1, 1440);
  await DB.setConfig('proactive_enabled', 'true');
  await DB.setConfig('proactive_interval', clamped.toString());

  final service = FlutterBackgroundService();

  // Configure once (idempotent)
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: _channelId,
      initialNotificationTitle: 'Solvhen',
      initialNotificationContent: '主动消息运行中（每$clamped分钟）',
      foregroundServiceNotificationId: _notifId,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onBackgroundStart,
      onBackground: onBackgroundStart,
    ),
  );

  // Start (or restart with new interval if already running)
  final isRunning = await service.isRunning();
  if (isRunning) {
    // Already running — just tell it to change interval
    service.invoke('setInterval', {'interval': clamped});
  } else {
    await service.startService();
    // Wait a tick for the service to init, then send interval
    await Future.delayed(const Duration(milliseconds: 500));
    service.invoke('setInterval', {'interval': clamped});
  }

  debugPrint('[Proactive] started via bg service, interval: ${clamped}min');
}

/// Stop proactive messaging.
Future<void> stopProactive() async {
  await DB.setConfig('proactive_enabled', 'false');
  final service = FlutterBackgroundService();
  service.invoke('stopService');
  debugPrint('[Proactive] stopped');
}

/// Check if proactive is enabled (reads config, not service state).
Future<bool> isProactiveRunning() async {
  final cfg = await DB.getConfig();
  return cfg['proactive_enabled'] == 'true';
}

// ═══════════════════════════════════════
// Helpers — duplicated in background entry point (top-level functions)
// ═══════════════════════════════════════

Future<String> _loadPersonality() async {
  try {
    final buf = StringBuffer();
    for (final path in ['assets/personality/base-identity.md',
                        'assets/personality/base-voice.md',
                        'assets/personality/base-constraints.md']) {
      try {
        final content = await rootBundle.loadString(path);
        buf.writeln(content);
      } catch (_) {}
    }
    if (buf.isNotEmpty) return buf.toString();
  } catch (_) {}
  return '你是 Solvhen，一个真实、有温度的手机智能体。用自然口语交流，像朋友一样。';
}

Future<String> _loadMemories() async {
  try {
    final mems = await DB.getGlobalMemories();
    if (mems.isEmpty) return '（还不太了解对方）';
    final buf = StringBuffer();
    for (final e in mems.entries) {
      for (final c in e.value) {
        buf.writeln('- [${e.key}] $c');
      }
    }
    return buf.toString();
  } catch (_) { return '（记忆加载失败）'; }
}

Future<String> _loadRecentChat() async {
  try {
    final convs = await DB.getConversations();
    if (convs.isEmpty) return '（还没有对话）';
    final msgs = await DB.getMessages(convs.first.id!, limit: 6);
    final buf = StringBuffer();
    for (final r in msgs) {
      final role = r['role'] == 'user' ? '对方' : '你';
      final c = (r['content'] as String).length > 60
          ? '${(r['content'] as String).substring(0, 60)}…'
          : r['content'] as String;
      buf.writeln('[$role]: $c');
    }
    return buf.toString();
  } catch (_) { return '（对话加载失败）'; }
}

Future<int> _getActiveConvId() async {
  try {
    final id = await DB.getActiveConversationId();
    if (id > 0) return id;
  } catch (_) {}
  final convs = await DB.getConversations();
  if (convs.isNotEmpty) return convs.first.id!;
  final c = await DB.createConversation(title: 'Solvhen');
  return c.id!;
}

Future<void> _saveMessage(int convId, String text) async {
  final db = await DB.database;
  final now = DateTime.now().toIso8601String();
  await db.insert('messages', {
    'content': text, 'role': 'assistant', 'conversation_id': convId,
    'timestamp': now, 'token_count': text.length ~/ 2,
  });
  await db.update('conversations', {'updated_at': now},
    where: 'id = ?', whereArgs: [convId]);
}
