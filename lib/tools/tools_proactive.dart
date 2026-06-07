/// Solvhen — 主动消息工具
library;

import 'dart:convert';
import 'tool_registry.dart';
import '../services/database_service.dart' as dbs;
import '../services/proactive_service.dart';

void registerProactiveTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'set_proactive',
    toolset: 'system',
    schema: {
      'name': 'set_proactive',
      'description': '设置主动消息间隔。Solvhen 会定时主动发消息给用户（通过系统通知）。设为0关闭。最少5分钟。',
      'parameters': {
        'type': 'object',
        'properties': {
          'minutes': {'type': 'integer', 'description': '间隔分钟数，0=关闭，最少5'},
        },
      },
    },
    handler: (args) async {
      final minutes = (args['minutes'] as num?)?.toInt() ?? 0;
      if (minutes <= 0) {
        await dbs.DB.setConfig('proactive_enabled', 'false');
        await ProactiveService().stop();
        return jsonEncode({'enabled': false});
      }
      final clamped = minutes.clamp(5, 1440);
      await dbs.DB.setConfig('proactive_enabled', 'true');
      await dbs.DB.setConfig('proactive_interval', clamped.toString());
      await ProactiveService().start();
      return jsonEncode({'enabled': true, 'interval': clamped});
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
        'interval_minutes': int.tryParse(cfg['proactive_interval'] ?? '30') ?? 30,
        'running': ProactiveService().isRunning,
      });
    },
  ));
}
