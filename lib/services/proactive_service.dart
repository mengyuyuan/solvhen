// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — Timer + WorkManager 双保险
// Timer: 即时响应 (1-14min), WorkManager: 兜底保活 (15min)
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:workmanager/workmanager.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

const _keeperId = 999;
const _wmTaskName = 'proactive_tick';

// ═══════════════════════════════════════
// WorkManager 后台回调 —— 兜底保活
// ═══════════════════════════════════════

@pragma('vm:entry-point')
void proactiveCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _wmTaskName) {
      return await runProactiveTick();
    }
    return false;
  });
}

/// 公开的 tick 入口——Timer 和 WorkManager 都走这里
Future<bool> runProactiveTick() async {
  if (_ticking) return true; // 已在执行中，跳过
  _ticking = true;
  try {
    final now = DateTime.now();

    final cfg = await DB.getConfig();
    if (cfg['proactive_enabled'] != 'true') {
      debugPrint('[Proactive] disabled, skipping tick');
      return true;
    }

    // 冲突检测
    final lastActivity = cfg['last_activity_at'];
    if (lastActivity != null) {
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
    if (text.isEmpty || text == '[SKIP]') return true;

    final convId = await _getActiveConvId();
    await _saveMessage(convId, text);

    await NotificationService().show(
      title: 'Solvhen',
      body: text,
      payload: jsonEncode({'action': 'open_conv', 'convId': convId}),
    );

    debugPrint('[Proactive] sent: $text -> conv $convId');
    return true;
  } catch (e) {
    debugPrint('[Proactive] tick error: $e');
    return false;
  } finally {
    _ticking = false;
  }
}

// ═══════════════════════════════════════
// Public API
// ═══════════════════════════════════════

Future<void> startProactive({required int intervalMinutes}) async {
  final clamped = intervalMinutes.clamp(1, 1440);

  // 持久化配置
  await DB.setConfig('proactive_enabled', 'true');
  await DB.setConfig('proactive_interval', clamped.toString());

  // 前台通知
  await NotificationService().cancel(_keeperId);
  await NotificationService().show(
    id: _keeperId,
    title: 'Solvhen',
    body: '主动消息运行中（每${clamped}分钟）',
    payload: 'proactive_keeper',
    ongoing: true,
  );

  // Timer — 即时响应
  _scheduleTick(clamped);

  // WorkManager — 兜底保活 (最小15分钟)
  try {
    await Workmanager().registerPeriodicTask(
      _wmTaskName,
      _wmTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
    debugPrint('[Proactive] WorkManager registered (15min fallback)');
  } catch (e) {
    debugPrint('[Proactive] WorkManager registration failed: $e');
  }

  // 首次 tick 不延迟
  await runProactiveTick();
  debugPrint('[Proactive] started, interval: ${clamped}min');
}

Future<void> stopProactive() async {
  await DB.setConfig('proactive_enabled', 'false');
  _cancelTimer();
  await NotificationService().cancel(_keeperId);

  try {
    await Workmanager().cancelByUniqueName(_wmTaskName);
    debugPrint('[Proactive] WorkManager cancelled');
  } catch (_) {}
}

Future<bool> isProactiveRunning() async {
  final cfg = await DB.getConfig();
  return cfg['proactive_enabled'] == 'true';
}

// ═══════════════════════════════════════
// Timer
// ═══════════════════════════════════════

Timer? _timer;
bool _ticking = false;

void _scheduleTick(int minutes) {
  _timer?.cancel();
  _timer = Timer(Duration(minutes: minutes), () async {
    debugPrint('[Proactive] timer fired');
    await runProactiveTick();
    // 重调度
    final cfg = await DB.getConfig();
    final m = int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30;
    _scheduleTick(m.clamp(1, 1440));
  });
}

void _cancelTimer() {
  _timer?.cancel();
  _timer = null;
}

// ═══════════════════════════════════════
// Helpers
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
