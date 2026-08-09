/// Solvhen AI手机智能体 — 工具注册中心（单例模式）
/// 所有工具模块通过此注册中心注册、查询和分发。
/// 支持创建独立实例（isolated）用于子 agent 的受限工具集。
library;

import 'dart:convert';
import '../core/agent/cancellation.dart';
import '../core/security/tool_security.dart';
import '../services/database_service.dart';

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
  List<Map<String, dynamic>> getDefinitions(
    Set<String> toolNames, {
    ExecutionOrigin origin = ExecutionOrigin.localUser,
  }) {
    return toolNames
        .map((name) => _tools[name])
        .where((e) =>
            e != null &&
            e.effectiveOrigins.contains(origin) &&
            SecuritySession.instance
                .areCapabilitiesAllowed(e.effectiveCapabilities) &&
            (e.checkFn?.call() ?? true))
        .map((e) => {
              'type': 'function',
              'function': e!.schema,
            })
        .toList();
  }

  /// 按名称分发并执行工具处理函数。
  /// 返回 JSON 字符串结果。未知工具或执行失败返回错误 JSON。
  Future<String> dispatch(
    String name,
    Map<String, dynamic> args, {
    ToolContext? context,
    ToolApprovalCallback? onApproval,
  }) async {
    final entry = _tools[name];
    if (entry == null) return jsonEncode({'error': 'Unknown tool: $name'});
    final effectiveContext = context ??
        ToolContext(
          requestId: 'direct_${DateTime.now().microsecondsSinceEpoch}',
          origin: ExecutionOrigin.localUser,
          cancellation: AgentCancellationToken(),
        );
    effectiveContext.cancellation.throwIfCancelled();
    final decision = const ToolPolicyEngine().evaluate(
      toolName: name,
      risk: entry.effectiveRisk,
      capabilities: entry.effectiveCapabilities,
      supportedOrigins: entry.effectiveOrigins,
      context: effectiveContext,
    );
    int? auditId;
    try {
      auditId = await DB.startToolAudit(
        requestId: effectiveContext.requestId,
        origin: effectiveContext.origin.name,
        toolName: name,
        risk: entry.effectiveRisk.name,
        argumentsRedacted: jsonEncode(_redactArguments(args)),
        decision: decision.name,
      );
    } catch (_) {
      // Auditing is best-effort and must not make tools unavailable.
    }

    if (decision == PolicyDecision.deny) {
      final errorCode =
          !entry.effectiveOrigins.contains(effectiveContext.origin)
              ? 'origin_not_allowed'
              : !SecuritySession.instance
                      .areCapabilitiesAllowed(entry.effectiveCapabilities)
                  ? 'capability_disabled'
                  : 'policy_denied';
      await _finishAudit(auditId, 'denied', errorCode);
      return jsonEncode({
        'error': 'Tool denied by policy',
        'tool': name,
        'reason': errorCode,
      });
    }
    if (decision == PolicyDecision.confirm) {
      final approval = onApproval ?? effectiveContext.approval;
      if (approval == null) {
        await _finishAudit(auditId, 'denied', 'approval_required');
        return jsonEncode({'error': 'User approval required', 'tool': name});
      }
      final approved = await approval(ToolApprovalRequest(
        toolName: name,
        risk: entry.effectiveRisk,
        capabilities: entry.effectiveCapabilities,
        arguments: _approvalArguments(args),
        context: effectiveContext,
      ));
      if (!approved) {
        await _finishAudit(auditId, 'denied', 'user_denied');
        return jsonEncode(
            {'error': 'User denied tool execution', 'tool': name});
      }
    }

    try {
      effectiveContext.cancellation.throwIfCancelled();
      final result = await entry.invoke(args, effectiveContext);
      await _finishAudit(auditId, 'completed', null);
      return result;
    } catch (e) {
      await _finishAudit(auditId, 'failed', e.runtimeType.toString());
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

  Future<void> _finishAudit(int? id, String status, String? errorCode) async {
    if (id == null) return;
    try {
      await DB.finishToolAudit(id: id, status: status, errorCode: errorCode);
    } catch (_) {}
  }

  Map<String, dynamic> _redactArguments(Map<String, dynamic> args) {
    final redacted = <String, dynamic>{};
    for (final item in args.entries) {
      final key = item.key.toLowerCase();
      final sensitive = const {
        'key',
        'token',
        'secret',
        'password',
        'authorization',
        'content',
        'message',
        'text',
        'code',
        'handler_code',
      }.any(key.contains);
      if (sensitive) {
        final value = item.value?.toString() ?? '';
        redacted[item.key] = '<redacted:${value.length} chars>';
      } else {
        redacted[item.key] = item.value;
      }
    }
    return redacted;
  }

  /// Confirmation panels need to show executable code before the user makes a
  /// decision. Audit logs still use [_redactArguments] and never retain it.
  Map<String, dynamic> _approvalArguments(Map<String, dynamic> args) {
    final visible = <String, dynamic>{};
    for (final item in args.entries) {
      final key = item.key.toLowerCase();
      final secret = const {
        'key',
        'token',
        'secret',
        'password',
        'authorization',
      }.any(key.contains);
      if (secret) {
        visible[item.key] = '<redacted>';
        continue;
      }
      final value = item.value;
      if (value is String && value.length > 4000) {
        visible[item.key] = '${value.substring(0, 4000)}\n…<truncated>';
      } else {
        visible[item.key] = value;
      }
    }
    return visible;
  }

  /// 检查工具是否已注册。
  bool contains(String name) => _tools.containsKey(name);

  /// 按名称获取工具条目。
  ToolEntry? operator [](String name) => _tools[name];

  /// 获取所有已注册的工具名称集合。
  Set<String> get names => _tools.keys.toSet();

  /// 获取所有工具的定义（OpenAI function calling 格式）。
  List<Map<String, dynamic>> getToolDefs({
    ExecutionOrigin origin = ExecutionOrigin.localUser,
  }) =>
      getDefinitions(names, origin: origin);
}

/// 单个工具的完整定义——包含 schema 和 handler。
class ToolEntry {
  final String name; // 工具唯一名称
  final String toolset; // 所属工具集（用于分类和权限控制）
  final Map<String, dynamic>
      schema; // OpenAI function schema (name/description/parameters)
  final Future<String> Function(Map<String, dynamic> args) handler; // 工具处理函数
  final Future<String> Function(Map<String, dynamic> args, ToolContext context)?
      contextualHandler;
  final bool Function()? checkFn; // 可选——返回 false 时工具暂时不可用（如权限未授予）
  final ToolRisk? risk;
  final Set<String> capabilities;
  final Set<ExecutionOrigin>? supportedOrigins;

  const ToolEntry({
    required this.name,
    required this.toolset,
    required this.schema,
    required this.handler,
    this.contextualHandler,
    this.checkFn,
    this.risk,
    this.capabilities = const {},
    this.supportedOrigins,
  });

  ToolRisk get effectiveRisk => risk ?? inferToolRisk(name, toolset);
  Set<String> get effectiveCapabilities =>
      capabilities.isEmpty ? {toolset} : capabilities;
  Set<ExecutionOrigin> get effectiveOrigins =>
      supportedOrigins ?? inferSupportedOrigins(name, toolset);

  Future<String> invoke(Map<String, dynamic> args, ToolContext context) =>
      contextualHandler?.call(args, context) ?? handler(args);
}
