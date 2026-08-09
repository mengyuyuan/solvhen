/// Solvhen AI手机智能体 — 多代理委派工具
/// 生成独立子 agent 并行处理任务，子 agent 在隔离上下文中运行。
/// 支持单任务模式和批量并行模式（最多3个）。
library;

import 'dart:convert';
import '../core/security/tool_security.dart';
import 'tool_registry.dart';
import '../services/sub_agent.dart';

/// 注册子代理委派工具
/// 工具：delegate_task(委派独立任务给SubAgent执行)
/// ⚠️ 子代理无父级记忆——需通过context传递全部必要信息
void registerDelegateTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'delegate_task',
    toolset: 'delegation',
    schema: {
      'name': 'delegate_task',
      'description': '''生成一个或多个子agent并行处理任务。子agent在隔离上下文中运行——有自己的消息历史和工具集。
中间结果不进入你的主上下文，只返回最终摘要。

单任务: delegate_task({goal:"...", context:"...", toolsets:["web"]})
批量并行: delegate_task({tasks:[{goal:"...", toolsets:["web"]}, {goal:"..."}]})

toolsets (可选；必须显式列出，省略时为纯文本子任务):
  web: 搜索+网络请求
  file: 文件读写
  system: 系统控制
  memory: 记忆操作
  history: 历史搜索

使用场景:
- "帮我同时查A和B" → 两个子agent并行搜索
- "分析这段代码并搜相关文档" → 子agent搜文档+你自己分析代码
- 复杂研究任务 → 拆成多个子任务并行''',
      'parameters': {
        'type': 'object',
        'properties': {
          'goal': {'type': 'string', 'description': '单个任务描述'},
          'context': {'type': 'string', 'description': '额外背景信息'},
          'toolsets': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '子agent可用工具集，默认全部',
          },
          'tasks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'goal': {'type': 'string'},
                'context': {'type': 'string'},
                'toolsets': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
              },
              'required': ['goal'],
            },
            'description': '批量并行任务列表（与 goal 互斥）',
          },
        },
        'required': [],
      },
    },
    handler: (args) => _runDelegation(args, null),
    contextualHandler: _runDelegation,
  ));
}

Future<String> _runDelegation(
  Map<String, dynamic> args,
  ToolContext? parentContext,
) async {
  final runner = SubAgentRunner();

  // 批量并行模式：同时执行多个子任务
  if (args['tasks'] != null) {
    final taskList = args['tasks'] as List<dynamic>;
    if (taskList.isEmpty) {
      return jsonEncode({'error': 'tasks 不能为空'});
    }
    if (taskList.length > 3) {
      return jsonEncode({'error': '最多3个子任务并行'});
    }

    final configs = taskList
        .map((t) {
          final m = t as Map<String, dynamic>;
          final goal = m['goal'];
          if (goal == null || goal is! String) {
            return null; // 无效任务将被过滤
          }
          return SubAgentConfig(
            goal: goal,
            context: m['context'] as String?,
            toolsets: (m['toolsets'] as List<dynamic>?)?.cast<String>(),
          );
        })
        .whereType<SubAgentConfig>()
        .toList();

    if (configs.isEmpty) {
      return jsonEncode({'error': 'tasks 中每个任务需要提供有效的 goal 字段'});
    }

    final results = await runner.runParallel(
      configs,
      parentContext: parentContext,
    );
    return jsonEncode({
      'results': results.map((r) => r.toJson()).toList(),
      'parallel': true,
      'count': results.length,
    });
  }

  // 单任务模式
  if (args['goal'] == null) {
    return jsonEncode({'error': '请提供 goal 或 tasks'});
  }

  final config = SubAgentConfig(
    goal: args['goal'] as String,
    context: args['context'] as String?,
    toolsets: (args['toolsets'] as List<dynamic>?)?.cast<String>(),
  );

  final result = await runner.run(config, parentContext: parentContext);
  return jsonEncode(result.toJson());
}
