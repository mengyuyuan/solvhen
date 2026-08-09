import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/core/agent/cancellation.dart';
import 'package:solvhen/core/security/developer_mode.dart';
import 'package:solvhen/core/security/tool_security.dart';
import 'package:solvhen/tools/tool_registry.dart';
import 'package:solvhen/tools/tools_code.dart';

void main() {
  setUp(() {
    SecuritySession.instance
      ..setTrusted(false)
      ..hydratePermissions(const {});
    DeveloperModeSession.instance.setEnabled(false);
  });

  test('developer URL accepts only loopback and private addresses', () {
    expect(
      normalizePrivateDeveloperUrl('http://192.168.1.10:9120').toString(),
      'http://192.168.1.10:9120',
    );
    expect(
      normalizePrivateDeveloperUrl('https://[::1]:9120/dev').toString(),
      'https://[::1]:9120/dev',
    );
    expect(normalizePrivateDeveloperUrl('http://localhost:9120'), isNotNull);

    expect(normalizePrivateDeveloperUrl('https://example.com'), isNull);
    expect(normalizePrivateDeveloperUrl('http://0.0.0.0:9120'), isNull);
    expect(normalizePrivateDeveloperUrl('http://[::]:9120'), isNull);
    expect(
      normalizePrivateDeveloperUrl('http://user:pass@192.168.1.10:9120'),
      isNull,
    );
    expect(
      normalizePrivateDeveloperUrl('http://192.168.1.10:9120?token=leak'),
      isNull,
    );
  });

  test('rebuild tool is hidden unless developer mode is enabled', () {
    registerCodeTool();
    final registry = ToolRegistry();

    expect(
      registry.getDefinitions({'rebuild_self'}),
      isEmpty,
    );
    DeveloperModeSession.instance.setEnabled(true);
    expect(
      registry.getDefinitions({'rebuild_self'}),
      hasLength(1),
    );
  });

  test('dynamic DSL previews code and scopes every nested tool', () async {
    registerDynamicTools();
    final registry = ToolRegistry();
    var probeCalls = 0;
    registry.register(ToolEntry(
      name: 'dynamic_probe',
      toolset: 'system',
      schema: const {
        'name': 'dynamic_probe',
        'description': 'test probe',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
      risk: ToolRisk.read,
      handler: (_) async {
        probeCalls++;
        return '{"success":true}';
      },
    ));

    final approvalArguments = <Map<String, dynamic>>[];
    Future<bool> approve(ToolApprovalRequest request) async {
      approvalArguments.add(request.arguments);
      return true;
    }

    final context = ToolContext(
      requestId: 'dynamic-test',
      origin: ExecutionOrigin.localUser,
      cancellation: AgentCancellationToken(),
      approval: approve,
    );
    const code = "tool('dynamic_probe', {});\nprint('done');";
    final registration = jsonDecode(await registry.dispatch(
      'register_tool',
      const {
        'name': 'scoped_dynamic_probe',
        'description': 'Run the read-only probe',
        'parameters': {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        'handler_code': code,
        'capabilities': ['system'],
      },
      context: context,
    )) as Map<String, dynamic>;

    expect(registration['registered'], isTrue);
    expect(approvalArguments.single['handler_code'], code);
    expect(approvalArguments.single['capabilities'], ['system']);

    final result = await registry.dispatch(
      'scoped_dynamic_probe',
      const {},
      context: context,
    );
    expect(result, contains('done'));
    expect(probeCalls, 1);

    final denied = jsonDecode(await registry.dispatch(
      'register_tool',
      const {
        'name': 'undeclared_probe',
        'description': 'Invalid capability declaration',
        'parameters': {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        'handler_code': "tool('dynamic_probe', {});",
        'capabilities': <String>[],
      },
      context: context,
    )) as Map<String, dynamic>;
    expect(denied['registered'], isFalse);
    expect(denied['error'], contains('声明能力'));

    registry
      ..unregister('scoped_dynamic_probe')
      ..unregister('dynamic_probe');
  });
}
