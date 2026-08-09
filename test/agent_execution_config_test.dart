import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/core/agent/agent_execution_config.dart';
import 'package:solvhen/core/agent/agent_run.dart';
import 'package:solvhen/core/security/tool_security.dart';

void main() {
  test('execution values normalize to documented finite ranges', () {
    const raw = AgentExecutionConfig(
      stepsPerLoop: 999,
      maxLoops: 999,
      timeoutMinutes: 999,
    );

    final config = raw.normalized();

    expect(config.stepsPerLoop, AgentExecutionConfig.maxStepsPerLoop);
    expect(config.maxLoops, AgentExecutionConfig.maxLoopsAllowed);
    expect(config.timeoutMinutes, AgentExecutionConfig.maxTimeoutMinutes);
    expect(config.maximumToolSteps, 1000);
  });

  test('single-loop mode ignores stored extra loop count', () {
    const config = AgentExecutionConfig(
      stepsPerLoop: 30,
      maxLoops: 8,
      loopMode: AgentLoopMode.single,
    );

    expect(config.effectiveLoops, 1);
    expect(config.maximumToolSteps, 30);
  });

  test('run advances in configured loop blocks and remains finite', () {
    final run = AgentRunSession(
      id: 'loops',
      conversationId: 1,
      origin: ExecutionOrigin.localUser,
      stepsPerLoop: 5,
      maxLoops: 3,
      loopMode: AgentLoopMode.automatic,
    );

    for (var index = 0; index < 5; index++) {
      run.beginIteration();
    }
    expect(run.canContinue, isFalse);
    expect(run.currentLoop, 1);
    run.extendBudget();
    expect(run.currentLoop, 2);
    for (var index = 0; index < 5; index++) {
      run.beginIteration();
    }
    run.extendBudget();
    expect(run.currentLoop, 3);
    for (var index = 0; index < 5; index++) {
      run.beginIteration();
    }

    expect(run.iterations, 15);
    expect(run.canContinue, isFalse);
    expect(run.canExtendBudget, isFalse);
    expect(run.hardIterationLimit, 15);
  });
}
