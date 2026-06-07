// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主动消息服务 — 定时生成并推送消息给用户
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'memory_service.dart';
import 'tool_executor.dart';
import '../services/notification_service.dart';

/// 主动消息服务 — 单例，按配置的间隔定时推送消息
class ProactiveService {
  static final ProactiveService _instance = ProactiveService._();
  factory ProactiveService() => _instance;
  ProactiveService._();

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _running;

  /// 启动定时器（根据 DB 配置）
  Future<void> start() async {
    await stop();
    final cfg = await DB.getConfig();
    final enabled = cfg['proactive_enabled'];
    if (enabled != 'true') return;

    final minutesStr = cfg['proactive_interval'] ?? '30';
    final minutes = int.tryParse(minutesStr) ?? 30;
    if (minutes < 5) return; // 最少5分钟

    _running = true;
    debugPrint('[Proactive] started, interval: ${minutes}min');
    _scheduleNext(Duration(minutes: minutes));
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () async {
      if (!_running) return;
      await _tick();
      // 读取最新配置，可能用户改了间隔
      final cfg = await DB.getConfig();
      final minutesStr = cfg['proactive_interval'] ?? '30';
      final minutes = int.tryParse(minutesStr) ?? 30;
      _scheduleNext(Duration(minutes: minutes.clamp(5, 1440)));
    });
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 生成一条主动消息并推送
  Future<void> _tick() async {
    try {
      final mem = MemoryService();
      final api = ApiService();

      // 获取最近的记忆和对话上下文
      final memories = await mem.getTopMemories(limit: 10);
      final memText = memories.map((m) => '- [${m.category}] ${m.content}').join('\n');

      final prompt = '''你是 Solvhen，正在主动联系你的用户。这不是对方发起的对话——是你主动的。

关于对方你知道：
$memText

现在的时间是 ${DateTime.now().hour}点${DateTime.now().minute}分。

请用一句自然的话跟对方打个招呼或分享一个想法。不要问"在吗""在干嘛"这种空洞的话。可以：
- 分享你刚才想到的一个有趣的事
- 提到你记得的对方的某件事（如果有的话）
- 简单地说你还在，没有忘记对方
- 如果太晚了（22点后），就别发了，回复 [SKIP]

回复要短——控制在20字以内最好。像老朋友随手发的一条消息。不要用任何标榜自己是AI的说法。''';

      final result = await api.chatStream(
        systemPrompt: prompt,
        history: const [],
        userMessage: '',
      ).timeout(const Duration(seconds: 20));

      final text = ToolExecutor.stripToolCallsFromContent(result.content).trim();
      if (text.isEmpty || text == '[SKIP]') return;

      // 推送系统通知
      await NotificationService().show(
        title: 'Solvhen',
        body: text,
        payload: 'proactive',
      );

      debugPrint('[Proactive] sent: $text');
    } catch (e) {
      debugPrint('[Proactive] tick error: $e');
    }
  }
}
