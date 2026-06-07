// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — 前台常驻保活 + Timer + 人格 + 记忆 + 对话同步
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'prompt_builder.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

const _keeperId = 999;

/// 启动主动消息
Future<void> startProactive({required int intervalMinutes}) async {
  final clamped = intervalMinutes.clamp(1, 1440);
  await DB.setConfig('proactive_enabled', 'true');
  await DB.setConfig('proactive_interval', clamped.toString());

  // 前台常驻通知
  await NotificationService().show(
    id: _keeperId,
    title: 'Solvhen',
    body: '主动消息运行中（每${clamped}分钟）',
    payload: 'proactive_keeper',
    ongoing: true,
  );

  _scheduleTick(clamped);
  // 立即发第一条验证
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
// Timer
// ═══════════════════════════════════════

Timer? _timer;

void _scheduleTick(int minutes) {
  _timer?.cancel();
  _timer = Timer(Duration(minutes: minutes), () async {
    await _tick();
    final cfg = await DB.getConfig();
    if (cfg['proactive_enabled'] == 'true') {
      final m = int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30;
      _scheduleTick(m.clamp(1, 1440));
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

Future<void> _tick() async {
  try {
    final api = ApiService();
    final now = DateTime.now();

    // 人格（从文件加载）
    final personality = await _loadPersonality();
    // 全局记忆
    final memText = await _loadMemories();
    // 最近对话
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
      systemPrompt: prompt, history: const [], userMessage: '',
    ).timeout(const Duration(seconds: 20));

    final text = ToolExecutor.stripToolCallsFromContent(result.content).trim();
    if (text.isEmpty || text == '[SKIP]') return;

    // 获取活跃对话
    final convId = await _getActiveConvId();
    await _saveMessage(convId, text);

    // 通知（带 convId 路由）
    await NotificationService().show(
      title: 'Solvhen',
      body: text,
      payload: jsonEncode({'action': 'open_conv', 'convId': convId}),
    );

    debugPrint('[Proactive] sent: $text -> conv $convId');
  } catch (e) {
    debugPrint('[Proactive] tick error: $e');
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
      final f = File(path);
      if (await f.exists()) buf.writeln(await f.readAsString());
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
