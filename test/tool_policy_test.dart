import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/core/agent/cancellation.dart';
import 'package:solvhen/core/agent/agent_run.dart';
import 'package:solvhen/core/security/tool_security.dart';
import 'package:solvhen/tools/tool_registry.dart';

void main() {
  final context = ToolContext(
    requestId: 'test',
    origin: ExecutionOrigin.localUser,
    cancellation: AgentCancellationToken(),
  );

  setUp(() {
    SecuritySession.instance
      ..setTrusted(false)
      ..hydratePermissions(const {});
  });

  test('missing capability choice preserves existing access', () {
    final decision = const ToolPolicyEngine().evaluate(
      toolName: 'get_time',
      risk: ToolRisk.read,
      capabilities: const {'system'},
      supportedOrigins: const {ExecutionOrigin.localUser},
      context: context,
    );

    expect(decision, PolicyDecision.allow);
  });

  test('disabled capability denies even a read-only tool', () {
    SecuritySession.instance.setCapabilityAllowed('system', false);

    final decision = const ToolPolicyEngine().evaluate(
      toolName: 'get_time',
      risk: ToolRisk.read,
      capabilities: const {'system'},
      supportedOrigins: const {ExecutionOrigin.localUser},
      context: context,
    );

    expect(decision, PolicyDecision.deny);
  });

  test('trust mode never bypasses disabled capabilities', () {
    SecuritySession.instance
      ..setTrusted(true)
      ..setCapabilityAllowed('file', false);

    final decision = const ToolPolicyEngine().evaluate(
      toolName: 'write_file',
      risk: ToolRisk.modify,
      capabilities: const {'file'},
      supportedOrigins: const {ExecutionOrigin.localUser},
      context: context,
    );

    expect(decision, PolicyDecision.deny);
  });

  test('destructive tools still require confirmation in trust mode', () {
    SecuritySession.instance.setTrusted(true);

    final decision = const ToolPolicyEngine().evaluate(
      toolName: 'delete_file',
      risk: ToolRisk.destructive,
      capabilities: const {'file'},
      supportedOrigins: const {ExecutionOrigin.localUser},
      context: context,
    );

    expect(decision, PolicyDecision.confirm);
  });

  test('sub-agent cannot modify the device even in trust mode', () {
    SecuritySession.instance.setTrusted(true);
    final subAgentContext = ToolContext(
      requestId: 'sub-test',
      origin: ExecutionOrigin.subAgent,
      cancellation: AgentCancellationToken(),
    );

    final decision = const ToolPolicyEngine().evaluate(
      toolName: 'set_volume',
      risk: ToolRisk.modify,
      capabilities: const {'system'},
      supportedOrigins: const {ExecutionOrigin.subAgent},
      context: subAgentContext,
    );

    expect(decision, PolicyDecision.deny);
  });

  test('agent budget extends by configured loop size up to loop limit', () {
    final run = AgentRunSession(
      id: 'budget',
      conversationId: 1,
      origin: ExecutionOrigin.localUser,
      stepsPerLoop: 12,
      maxLoops: 3,
    );
    for (var i = 0; i < 12; i++) {
      run.beginIteration();
    }

    expect(run.canContinue, isFalse);
    expect(run.canExtendBudget, isTrue);
    expect(run.proposedIterationLimit, 24);
    run.extendBudget();
    expect(run.iterationLimit, 24);
    expect(run.currentLoop, 2);
    expect(run.canContinue, isTrue);
  });

  test('nested dynamic dispatch cannot bypass a disabled capability', () async {
    final registry = ToolRegistry.isolated();
    registry.register(ToolEntry(
      name: 'inner_read',
      toolset: 'file',
      schema: const {
        'name': 'inner_read',
        'parameters': {'type': 'object'},
      },
      handler: (_) async => '{"success":true}',
      risk: ToolRisk.read,
    ));
    registry.register(ToolEntry(
      name: 'outer_read',
      toolset: 'web',
      schema: const {
        'name': 'outer_read',
        'parameters': {'type': 'object'},
      },
      handler: (_) async => '{}',
      contextualHandler: (_, nestedContext) => registry.dispatch(
        'inner_read',
        const {},
        context: nestedContext.nested('outer_read'),
      ),
      risk: ToolRisk.read,
    ));
    SecuritySession.instance.setCapabilityAllowed('file', false);

    final result = await registry.dispatch(
      'outer_read',
      const {},
      context: context,
    );

    expect(result, contains('capability_disabled'));
  });
}
