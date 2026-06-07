/// Solvhen AI手机智能体 — 工具注册中心（单例模式）
/// 所有工具模块通过此注册中心注册、查询和分发。
/// 支持创建独立实例（isolated）用于子 agent 的受限工具集。
library;

import 'dart:convert';

/// 工具注册中心——所有工具的OpenAI function-calling schema定义+注册+分发
class ToolRegistry {
  static final ToolRegistry _instance = ToolRegistry._();
  factory ToolRegistry() => _instance;

  /// 创建完全独立的注册中心实例（非单例）。
  /// 用于子 agent——子 agent 不应继承全局全部工具，而是按需注册。
  factory ToolRegistry.isolated() => ToolRegistry._();

  ToolRegistry._();

  final _tools = <String, ToolEntry>{};

  /// 注册一个工具。同名工具会被覆盖——后注册的优先。
  void register(ToolEntry entry) {
    _tools[entry.name] = entry;
  }

  /// 移除一个工具。用于AI动态卸载自己注册的工具。
  /// 返回 true 表示移除成功，false 表示工具不存在。
  bool unregister(String name) {
    return _tools.remove(name) != null;
  }

  /// 返回指定工具集的 OpenAI function calling 格式定义。
  /// [toolNames] 为需要暴露的工具名称集合。
  List<Map<String, dynamic>> getDefinitions(Set<String> toolNames) {
    return toolNames
        .map((name) => _tools[name])
        .where((e) => e != null && (e.checkFn?.call() ?? true))
        .map((e) => {
              'type': 'function',
              'function': e!.schema,
            })
        .toList();
  }

  /// 按名称分发并执行工具处理函数。
  /// 返回 JSON 字符串结果。未知工具或执行失败返回错误 JSON。
  Future<String> dispatch(String name, Map<String, dynamic> args) async {
    final entry = _tools[name];
    if (entry == null) return jsonEncode({'error': 'Unknown tool: $name'});
    try {
      return await entry.handler(args);
    } catch (e) {
      // 截断错误详情，避免超长错误消息污染上下文
      return jsonEncode({
        'error': 'Tool execution failed',
        'tool': name,
        'detail': e.toString().length > 200
            ? '${e.toString().substring(0, 200)}...'
            : e.toString(),
      });
    }
  }

  /// 检查工具是否已注册。
  bool contains(String name) => _tools.containsKey(name);

  /// 按名称获取工具条目。
  ToolEntry? operator [](String name) => _tools[name];

  /// 获取所有已注册的工具名称集合。
  Set<String> get names => _tools.keys.toSet();

  /// 获取所有工具的定义（OpenAI function calling 格式）。
  List<Map<String, dynamic>> getToolDefs() => getDefinitions(names);
}

/// 单个工具的完整定义——包含 schema 和 handler。
class ToolEntry {
  final String name;        // 工具唯一名称
  final String toolset;     // 所属工具集（用于分类和权限控制）
  final Map<String, dynamic> schema; // OpenAI function schema (name/description/parameters)
  final Future<String> Function(Map<String, dynamic> args) handler; // 工具处理函数
  final bool Function()? checkFn; // 可选——返回 false 时工具暂时不可用（如权限未授予）

  const ToolEntry({
    required this.name,
    required this.toolset,
    required this.schema,
    required this.handler,
    this.checkFn,
  });
}
