import 'dart:async';

import '../agent/cancellation.dart';

enum ToolRisk { read, modify, external, destructive }

enum ExecutionOrigin { localUser, oneBot, proactive, subAgent, dynamicTool }

enum PolicyDecision { allow, confirm, deny }

class ToolContext {
  const ToolContext({
    required this.requestId,
    required this.origin,
    required this.cancellation,
    this.conversationId,
    this.parentTool,
    this.approval,
  });

  final String requestId;
  final ExecutionOrigin origin;
  final AgentCancellationToken cancellation;
  final int? conversationId;
  final String? parentTool;
  final ToolApprovalCallback? approval;

  ToolContext nested(String toolName) => ToolContext(
        requestId: requestId,
        origin: origin,
        cancellation: cancellation,
        conversationId: conversationId,
        parentTool: toolName,
        approval: approval,
      );

  ToolContext withApproval(ToolApprovalCallback? callback) => ToolContext(
        requestId: requestId,
        origin: origin,
        cancellation: cancellation,
        conversationId: conversationId,
        parentTool: parentTool,
        approval: callback ?? approval,
      );

  ToolContext asOrigin(ExecutionOrigin newOrigin, {String? parent}) =>
      ToolContext(
        requestId: requestId,
        origin: newOrigin,
        cancellation: cancellation,
        conversationId: conversationId,
        parentTool: parent ?? parentTool,
        approval: approval,
      );
}

class ToolApprovalRequest {
  const ToolApprovalRequest({
    required this.toolName,
    required this.risk,
    required this.capabilities,
    required this.arguments,
    required this.context,
  });

  final String toolName;
  final ToolRisk risk;
  final Set<String> capabilities;
  final Map<String, dynamic> arguments;
  final ToolContext context;
}

typedef ToolApprovalCallback = Future<bool> Function(
    ToolApprovalRequest request);

class SecuritySession {
  SecuritySession._();
  static final SecuritySession instance = SecuritySession._();

  bool _trusted = false;
  final Map<String, bool> _capabilityPermissions = {};
  bool get trusted => _trusted;
  Map<String, bool> get capabilityPermissions =>
      Map.unmodifiable(_capabilityPermissions);

  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  Stream<bool> get changes => _changes.stream;

  void setTrusted(bool value) {
    if (_trusted == value) return;
    _trusted = value;
    _changes.add(value);
  }

  /// Loads persisted capability choices. Missing capabilities remain enabled so
  /// upgrades never silently remove an existing ability.
  void hydratePermissions(Map<String, bool> permissions) {
    _capabilityPermissions
      ..clear()
      ..addAll(permissions);
    _changes.add(_trusted);
  }

  bool isCapabilityAllowed(String capability) =>
      _capabilityPermissions[capability] ?? true;

  bool areCapabilitiesAllowed(Iterable<String> capabilities) =>
      capabilities.every(isCapabilityAllowed);

  Set<String> disabledCapabilities(Iterable<String> capabilities) =>
      capabilities.where((item) => !isCapabilityAllowed(item)).toSet();

  void setCapabilityAllowed(String capability, bool allowed) {
    if (_capabilityPermissions[capability] == allowed) return;
    _capabilityPermissions[capability] = allowed;
    _changes.add(_trusted);
  }

  void reset() => setTrusted(false);
}

class ToolPolicyEngine {
  const ToolPolicyEngine();

  PolicyDecision evaluate({
    required String toolName,
    required ToolRisk risk,
    required Set<String> capabilities,
    required Set<ExecutionOrigin> supportedOrigins,
    required ToolContext context,
  }) {
    if (!supportedOrigins.contains(context.origin)) return PolicyDecision.deny;
    if (!SecuritySession.instance.areCapabilitiesAllowed(capabilities)) {
      return PolicyDecision.deny;
    }

    // Remote/background/child origins are scoped before confirmation logic.
    // A forbidden operation must be denied, never upgraded into an approval
    // request that could accidentally grant a broader origin local-user power.
    switch (context.origin) {
      case ExecutionOrigin.oneBot:
        if (!_oneBotAllowed.contains(toolName) || risk != ToolRisk.read) {
          return PolicyDecision.deny;
        }
      case ExecutionOrigin.proactive:
        if (!_proactiveAllowed.contains(toolName) || risk != ToolRisk.read) {
          return PolicyDecision.deny;
        }
      case ExecutionOrigin.subAgent:
        if (risk != ToolRisk.read) return PolicyDecision.deny;
      case ExecutionOrigin.dynamicTool:
      case ExecutionOrigin.localUser:
        break;
    }

    if (_alwaysConfirm.contains(toolName) || risk == ToolRisk.destructive) {
      return PolicyDecision.confirm;
    }

    switch (context.origin) {
      case ExecutionOrigin.oneBot:
        return PolicyDecision.allow;
      case ExecutionOrigin.proactive:
        return PolicyDecision.allow;
      case ExecutionOrigin.subAgent:
        return PolicyDecision.allow;
      case ExecutionOrigin.dynamicTool:
      case ExecutionOrigin.localUser:
        if (risk == ToolRisk.read) return PolicyDecision.allow;
        return SecuritySession.instance.trusted
            ? PolicyDecision.allow
            : PolicyDecision.confirm;
    }
  }

  static const _alwaysConfirm = <String>{
    'delete_file',
    'lock_screen',
    'set_volume',
    'set_brightness',
    'toggle_wifi',
    'toggle_bluetooth',
    'set_ringer_mode',
    'input_tap',
    'input_swipe',
    'input_text',
    'click_text',
    'press_back',
    'press_home',
    'press_enter',
    'press_recent',
    'long_press',
    'device_act',
    'rebuild_self',
    'register_tool',
    'unregister_tool',
    'run_code',
    'set_proactive',
    'start_onebot',
    'stop_onebot',
  };

  static const _oneBotAllowed = <String>{
    'get_time',
    'web_search',
    'web_extract',
    'fetch_url',
    'search_memory',
    'list_memories',
  };

  static const _proactiveAllowed = <String>{
    'get_time',
    'get_battery',
    'search_memory',
    'list_memories',
    'search_history',
  };
}

ToolRisk inferToolRisk(String name, String toolset) {
  if (ToolPolicyEngine._alwaysConfirm.contains(name)) {
    return ToolRisk.destructive;
  }
  if (toolset == 'dynamic') return ToolRisk.destructive;
  // device_* 兜底：只有明确只读的才放行自动执行，其余按修改处理。
  if (toolset == 'device') {
    const readOnly = {
      'device_screen',
      'device_find',
      'device_wait',
      'device_app',
      'device_shot',
    };
    return readOnly.contains(name) ? ToolRisk.read : ToolRisk.modify;
  }
  if (const {
    'write_file',
    'save_memory',
    'link_memories',
    'remember_episode',
    'set_theme_color',
    'set_theme_mode',
    'set_bubble_color',
    'animate',
    'draw_expression',
    'spawn_particle',
    'modify_appearance',
    'layout_gesture',
    'render_html',
    'eval_js',
    'clear_canvas',
    'set_proactive',
    'save_skill',
    'switch_model',
    'use_model'
  }.contains(name)) {
    return ToolRisk.modify;
  }
  if (const {'open_app', 'set_clipboard', 'delegate_task', 'test_proactive'}
      .contains(name)) {
    return ToolRisk.external;
  }
  return ToolRisk.read;
}

Set<ExecutionOrigin> inferSupportedOrigins(String name, String toolset) {
  if (toolset == 'delegation' ||
      toolset == 'dynamic' ||
      toolset == 'code' ||
      const {'rebuild_self', 'register_tool', 'unregister_tool'}
          .contains(name)) {
    return const {ExecutionOrigin.localUser, ExecutionOrigin.dynamicTool};
  }
  return const {
    ExecutionOrigin.localUser,
    ExecutionOrigin.oneBot,
    ExecutionOrigin.proactive,
    ExecutionOrigin.subAgent,
    ExecutionOrigin.dynamicTool,
  };
}
