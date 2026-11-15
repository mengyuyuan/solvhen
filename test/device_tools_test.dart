import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/core/agent/cancellation.dart';
import 'package:solvhen/core/security/tool_security.dart';
import 'package:solvhen/tools/tool_registry.dart';
import 'package:solvhen/tools/tools_device.dart';

void main() {
  setUpAll(registerDeviceTools);

  test('device toolset registers the full control surface', () {
    const expected = {
      'device_screen',
      'device_find',
      'device_tap',
      'device_input',
      'device_scroll',
      'device_wait',
      'device_app',
      'device_dismiss',
      'device_shot',
      'device_act',
    };
    final registry = ToolRegistry();
    for (final name in expected) {
      expect(registry.contains(name), isTrue, reason: 'missing $name');
    }
  });

  test('read-only device tools never demand confirmation', () {
    final registry = ToolRegistry();
    for (final name in const [
      'device_screen',
      'device_find',
      'device_wait',
      'device_app',
      'device_shot',
    ]) {
      final entry = registry[name]!;
      expect(entry.effectiveRisk, ToolRisk.read, reason: name);
      expect(entry.effectiveCapabilities, contains('device'), reason: name);
    }
  });

  test('mutating device tools are gate-able, batch always confirms', () {
    final registry = ToolRegistry();
    for (final name in const [
      'device_tap',
      'device_input',
      'device_scroll',
      'device_dismiss',
    ]) {
      expect(registry[name]!.effectiveRisk, ToolRisk.modify, reason: name);
    }
    final batch = registry['device_act']!;
    expect(batch.effectiveRisk, ToolRisk.destructive);
    expect(
      const ToolPolicyEngine().evaluate(
        toolName: 'device_act',
        risk: batch.effectiveRisk,
        capabilities: batch.effectiveCapabilities,
        supportedOrigins: batch.effectiveOrigins,
        context: ToolContext(
          requestId: 'device_act_test',
          origin: ExecutionOrigin.localUser,
          cancellation: AgentCancellationToken(),
        ),
      ),
      PolicyDecision.confirm,
    );
  });
  test('device_act asks for confirmation and rejects empty steps once approved',
      () async {
    // 未提供确认回调时，破坏性工具必须在策略层就被拦下，绝不触达设备。
    final blocked = jsonDecode(await ToolRegistry().dispatch(
      'device_act',
      {
        'steps': <Object>[],
      },
    )) as Map<String, dynamic>;
    expect(blocked['ok'], isNull);
    expect(blocked['error'], contains('approval'));

    // 用户确认后进入参数校验：空序列不应调用任何设备接口。
    var asked = false;
    final approved = jsonDecode(await ToolRegistry().dispatch(
      'device_act',
      {
        'steps': <Object>[],
      },
      onApproval: (request) async {
        asked = true;
        return true;
      },
    )) as Map<String, dynamic>;
    expect(asked, isTrue);
    expect(approved['ok'], isFalse);
    expect(approved['error'], contains('steps'));
  });
}
