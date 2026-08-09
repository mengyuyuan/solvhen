/// Solvhen — 主动消息工具
library;

import 'dart:convert';
import 'tool_registry.dart';
import '../services/database_service.dart' as dbs;
import '../services/proactive_service.dart';
import '../services/notification_service.dart';

void registerProactiveTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'set_proactive',
    toolset: 'system',
    schema: {
      'name': 'set_proactive',
      'description':
          '设置主动消息间隔。0=关闭，范围1–1440分钟。1–14分钟会启动带常驻通知的前台服务，15分钟以上使用WorkManager。',
      'parameters': {
        'type': 'object',
        'properties': {
          'minutes': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 1440,
            'description': '间隔分钟数，0=关闭',
          },
        },
      },
    },
    handler: (args) async {
      final minutes = (args['minutes'] as num?)?.toInt() ?? 0;
      if (minutes <= 0) {
        await dbs.DB.setConfig('proactive_enabled', 'false');
        await stopProactive();
        return jsonEncode({'enabled': false});
      }
      final clamped = minutes.clamp(1, 1440);
      await startProactive(intervalMinutes: clamped);
      return jsonEncode({
        'enabled': true,
        'interval': clamped,
        'schedule': clamped < 15 ? 'foreground_service' : 'workmanager',
      });
    },
  ));

  registry.register(ToolEntry(
    name: 'test_proactive',
    toolset: 'system',
    schema: {
      'name': 'test_proactive',
      'description': '立即发送一条测试主动消息',
      'parameters': {'type': 'object', 'properties': {}},
    },
    handler: (args) async {
      try {
        await NotificationService().show(
          title: 'Solvhen',
          body: '这是一条测试主动消息。后台定时器正常。',
          payload: jsonEncode({'action': 'test'}),
        );
        return jsonEncode({'sent': true});
      } catch (e) {
        return jsonEncode({'sent': false, 'error': e.toString()});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'proactive_status',
    toolset: 'system',
    schema: {
      'name': 'proactive_status',
      'description': '查看主动消息设置状态',
      'parameters': {'type': 'object', 'properties': {}},
    },
    handler: (args) async {
      final cfg = await dbs.DB.getConfig();
      return jsonEncode({
        'enabled': cfg['proactive_enabled'] == 'true',
        'interval_minutes':
            int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30,
        'last_tick': cfg['last_proactive_tick'],
        'last_error': cfg['last_proactive_error'],
        'schedule_mode': cfg['proactive_schedule_mode'] ?? 'disabled',
        'note': '1–14分钟=常驻前台服务；15分钟以上=WorkManager',
      });
    },
  ));
}
