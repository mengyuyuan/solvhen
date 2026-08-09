// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — 前台 Timer / WorkManager / 显式前台服务
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

const _periodicUniqueName = 'solvhen.proactive.periodic';
const _periodicTaskName = 'solvhen.proactive.tick';
const _foregroundServiceId = 991;
bool _schedulerInitialized = false;
bool _appInForeground = true;

enum ProactiveScheduleMode { foregroundTimer, workManager, foregroundService }

String proactiveScheduleModeLabel(int intervalMinutes) {
  if (intervalMinutes < 15) return '前台服务';
  return _appInForeground ? '前台 Timer + WorkManager' : 'WorkManager';
}

@pragma('vm:entry-point')
void proactiveWorkmanagerDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != _periodicTaskName) return true;
    return runProactiveTick(source: 'workmanager');
  });
}

@pragma('vm:entry-point')
void proactiveForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_ProactiveForegroundTaskHandler());
}

class _ProactiveForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(runProactiveTick(source: 'foreground_service'));
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

Future<void> initializeProactiveScheduling() async {
  if (_schedulerInitialized ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  FlutterForegroundTask.initCommunicationPort();
  await Workmanager().initialize(proactiveWorkmanagerDispatcher);
  _schedulerInitialized = true;
}

/// 启动主动消息
Future<void> startProactive({
  required int intervalMinutes,
  bool sendImmediately = true,
}) async {
  final clamped = intervalMinutes.clamp(1, 1440);

  await DB.setConfig('proactive_enabled', 'true');
  await DB.setConfig('proactive_interval', clamped.toString());

  try {
    await initializeProactiveScheduling();
    await NotificationService().init();
    await _configureSchedule(clamped);
  } catch (_) {
    await DB.setConfig('proactive_enabled', 'false');
    await DB.setConfig('proactive_schedule_mode', 'failed');
    rethrow;
  }
  if (sendImmediately) {
    await runProactiveTick(
      ignoreRecentActivity: true,
      ignoreIntervalGuard: true,
      source: 'manual_enable',
    );
  }
  debugPrint(
      '[Proactive] started: $clamped min / ${proactiveScheduleModeLabel(clamped)}');
}

/// 停止
Future<void> stopProactive() async {
  await DB.setConfig('proactive_enabled', 'false');
  _cancelTimer();
  if (_schedulerInitialized) {
    await Workmanager().cancelByUniqueName(_periodicUniqueName);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await FlutterForegroundTask.stopService();
  }
  await DB.setConfig('proactive_schedule_mode', 'disabled');
  debugPrint('[Proactive] stopped');
}

Future<bool> isProactiveRunning() async {
  final cfg = await DB.getConfig();
  return cfg['proactive_enabled'] == 'true';
}

Future<void> setProactiveAppForeground(bool value) async {
  _appInForeground = value;
  if (!value) {
    _cancelTimer();
    return;
  }
  final config = await DB.getConfig();
  if (config['proactive_enabled'] != 'true') return;
  final minutes =
      (int.tryParse(config['proactive_interval'] ?? '30') ?? 30).clamp(1, 1440);
  if (minutes >= 15) _scheduleTick(minutes);
}

Future<void> _configureSchedule(int minutes) async {
  _cancelTimer();
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  if (!isAndroid) {
    if (_appInForeground) _scheduleTick(minutes);
    await DB.setConfig('proactive_schedule_mode', 'foreground_timer');
    return;
  }
  if (_schedulerInitialized) {
    await Workmanager().cancelByUniqueName(_periodicUniqueName);
  }
  await FlutterForegroundTask.stopService();

  if (minutes < 15) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'solvhen_proactive_foreground',
        channelName: 'Solvhen 高频主动消息',
        channelDescription: '1–14 分钟主动消息使用的常驻前台服务',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(minutes * 60 * 1000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
    final result = await FlutterForegroundTask.startService(
      serviceId: _foregroundServiceId,
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: 'Solvhen 主动消息运行中',
      notificationText: '高频模式 · 每 $minutes 分钟 · 点击返回应用',
      callback: proactiveForegroundCallback,
    );
    if (result is ServiceRequestFailure) {
      throw StateError('foreground_service_start_failed');
    }
    await DB.setConfig('proactive_schedule_mode', 'foreground_service');
    return;
  }

  await Workmanager().registerPeriodicTask(
    _periodicUniqueName,
    _periodicTaskName,
    frequency: Duration(minutes: minutes),
    initialDelay: Duration(minutes: minutes),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
  await DB.setConfig('proactive_schedule_mode', 'workmanager');
  if (_appInForeground) _scheduleTick(minutes);
}

// ═══════════════════════════════════════
// Timer — try/catch 包裹，任何异常都重调度
// ═══════════════════════════════════════

Timer? _timer;
bool _ticking = false;
DateTime? _lastTickAt;
String? _lastError;

/// 获取上次 tick 执行时间（null = 从未执行）
DateTime? getLastTickTime() => _lastTickAt;

/// 获取上次错误信息
String? getLastError() => _lastError;

void _scheduleTick(int minutes) {
  _timer?.cancel();
  _timer = Timer(Duration(minutes: minutes), () async {
    try {
      debugPrint('[Proactive] timer fired');
      await runProactiveTick(source: 'foreground_timer');
    } catch (e) {
      debugPrint('[Proactive] timer callback error: $e');
    }
    // 无论如何都重调度 —— 防止 DB 异常导致 Timer 永久死亡
    try {
      final cfg = await DB.getConfig();
      final m = int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30;
      if (_appInForeground && cfg['proactive_enabled'] == 'true' && m >= 15) {
        _scheduleTick(m.clamp(15, 1440));
      }
    } catch (e) {
      debugPrint('[Proactive] re-schedule error: ${e.runtimeType}');
    }
  });
}

void _cancelTimer() {
  _timer?.cancel();
  _timer = null;
}

// ═══════════════════════════════════════
// Tick
// ═══════════════════════════════════════

Future<bool> runProactiveTick({
  bool ignoreRecentActivity = false,
  bool ignoreIntervalGuard = false,
  String source = 'unknown',
}) async {
  if (_ticking) return true;
  _ticking = true;
  try {
    await NotificationService().init();
    final now = DateTime.now();
    _lastTickAt = now;
    await DB.setConfig('last_proactive_tick', now.toIso8601String());
    await DB.setConfig('last_proactive_source', source);

    final cfg = await DB.getConfig();
    if (cfg['proactive_enabled'] != 'true') {
      debugPrint('[Proactive] disabled, skipping');
      return true;
    }

    // WorkManager, the foreground Timer and a foreground-service isolate may
    // wake close together. The atomic claim prevents duplicate messages across
    // isolates/process restarts and is intentionally not replayed after a crash.
    final interval =
        (int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30).clamp(1, 1440);
    final claimed = await DB.tryClaimProactiveTick(
      now: now,
      intervalMinutes: interval,
      force: ignoreIntervalGuard,
    );
    if (!claimed) {
      debugPrint('[Proactive] skipped — interval already claimed');
      return true;
    }

    // 冲突检测：用户 2 分钟内有活动则跳过
    final lastActivity = cfg['last_activity_at'];
    if (!ignoreRecentActivity && lastActivity != null) {
      final lastTime = DateTime.tryParse(lastActivity);
      if (lastTime != null && now.difference(lastTime).inMinutes < 2) {
        debugPrint('[Proactive] skipped — user active recently');
        return true;
      }
    }

    final api = ApiService();
    final personality = await _loadPersonality();
    final memText = await _loadMemories();
    final chatText = await _loadRecentChat();

    final prompt = '''
$personality

[系统指令：现在是主动消息模式]
你正在后台主动联系用户。
当前时间：${now.hour}:${now.minute.toString().padLeft(2, '0')}

关于对方你知道：
$memText

最近对话：
$chatText

请用你的人格说一句自然的话联系对方。控制在20字以内。不要解释，不要提主动消息、定时器或工具。''';

    final result = await api
        .chatStream(
          systemPrompt: prompt,
          history: const [],
          userMessage: '（后台定时联系，请简短回复）',
        )
        .timeout(const Duration(seconds: 20));

    var text = ToolExecutor.stripToolCallsFromContent(result.content).trim();
    if (text.isEmpty || text == '[SKIP]') {
      text = '我在。';
    }

    final convId = await _getActiveConvId();
    await _saveMessage(convId, text);
    await DB.setConfig('last_proactive_sent_at', now.toIso8601String());

    await NotificationService().show(
      title: 'Solvhen',
      body: text,
      payload: jsonEncode({'action': 'open_conv', 'convId': convId}),
    );

    _lastError = null;
    await DB.setConfig('last_proactive_error', '');
    debugPrint('[Proactive] sent: $text -> conv $convId');
    return true;
  } catch (e) {
    final errorCode = e.runtimeType.toString();
    _lastError = errorCode;
    try {
      await DB.setConfig('last_proactive_error', errorCode);
    } catch (_) {}
    debugPrint('[Proactive] tick error: $errorCode');
    return false;
  } finally {
    _ticking = false;
  }
}

// ═══════════════════════════════════════
// Helpers
// ═══════════════════════════════════════

Future<String> _loadPersonality() async {
  try {
    final buf = StringBuffer();
    for (final path in [
      'assets/personality/base-identity.md',
      'assets/personality/base-voice.md',
      'assets/personality/base-constraints.md',
    ]) {
      try {
        buf.writeln(await rootBundle.loadString(path));
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
  } catch (_) {
    return '（记忆加载失败）';
  }
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
  } catch (_) {
    return '（对话加载失败）';
  }
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
    'content': text,
    'role': 'assistant',
    'conversation_id': convId,
    'timestamp': now,
    'token_count': text.length ~/ 2,
  });
  await db.update('conversations', {'updated_at': now},
      where: 'id = ?', whereArgs: [convId]);
}
