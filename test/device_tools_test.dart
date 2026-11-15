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

  test('device_act rejects an empty step list before touching the device', () async {
    final output = await ToolRegistry().dispatch('device_act', {'steps': <Object>[]});
    final decoded = jsonDecode(output) as Map<String, dynamic>;
    expect(decoded['ok'], isFalse);
    expect(decoded['error'], contains('steps'));
  });
}
