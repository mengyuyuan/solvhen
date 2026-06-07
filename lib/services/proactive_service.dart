// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — Dart Timer + 前台通知保活
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'api_service.dart';
import 'database_service.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

const _keeperId = 999;

/// 启动主动消息
Future<void> startProactive({required int intervalMinutes}) async {
  final clamped = intervalMinutes.clamp(1, 1440);
  await DB.setConfig('proactive_enabled', 'true');
  await DB.setConfig('proactive_interval', clamped.toString());

  // 更新常驻通知（先取消旧的再发新的，确保文字更新）
  await NotificationService().cancel(_keeperId);
  await NotificationService().show(
    id: _keeperId,
    title: 'Solvhen',
    body: '主动消息运行中（每${clamped}分钟）',
    payload: 'proactive_keeper',
    ongoing: true,
  );

  _scheduleTick(clamped);
  // 首次 tick 不延迟
  await _tick();
  debugPrint('[Proactive] started, interval: ${clamped}min');
}

/// 停止
Future<void> stopProactive() async {
  await DB.setConfig('proactive_enabled', 'false');
  _cancelTimer();
  await NotificationService().cancel(_keeperId);
}

Future<bool> isProactiveRunning() async {
  final cfg = await DB.getConfig();
  return cfg['proactive_enabled'] == 'true';
}

// ═══════════════════════════════════════
// Timer（防竞态）
// ═══════════════════════════════════════

Timer? _timer;
bool _ticking = false; // 并发锁

void _scheduleTick(int minutes) {
  _timer?.cancel();
  _timer = Timer(Duration(minutes: minutes), () async {
    debugPrint('[Proactive] timer fired, scheduling next...');
    await _tick();
    // 始终重调度——_tick()内部判断是否该跳过
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
// Tick
// ═══════════════════════════════════════

Future<void> _tick() async {
  if (_ticking) return;
  _ticking = true;
  try {
    final now = DateTime.now();

    // 已关闭则跳过
    final cfg = await DB.getConfig();
    if (cfg['proactive_enabled'] != 'true') {
      debugPrint('[Proactive] disabled, skipping tick');
      return;
    }
    // 冲突检测：用户最近5分钟有活动则跳过
    final lastActivity = cfg['last_activity_at'];
    if (lastActivity != null) {
      final lastTime = DateTime.tryParse(lastActivity);
      if (lastTime != null && now.difference(lastTime).inMinutes < 5) {
        debugPrint('[Proactive] skipped — user active recently');
        return;
      }
    }

    final api = ApiService();

    // P0修复: 用 rootBundle 读 asset 文件（不用 dart:io File）
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

    // 获取活跃对话
    final convId = await _getActiveConvId();
    await _saveMessage(convId, text);

    // 通知 + in-app push（ChatScreen 监听刷新）
    await NotificationService().show(
      title: 'Solvhen',
      body: text,
      payload: jsonEncode({'action': 'open_conv', 'convId': convId}),
    );

    debugPrint('[Proactive] sent: $text -> conv $convId');
  } catch (e) {
    debugPrint('[Proactive] tick error: $e');
  } finally {
    _ticking = false;
  }
}

// ═══════════════════════════════════════
// 辅助
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
      } catch (_) { /* 某个文件不存在不影响其他 */ }
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
