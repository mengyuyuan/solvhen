import 'dart:async';
import 'agent_execution_config.dart';
import '../security/tool_security.dart';
import 'cancellation.dart';

enum AgentRunState {
  idle,
  planning,
  awaitingApproval,
  executing,
  streaming,
  completed,
  cancelled,
  failed,
}

class AgentRunSession {
  AgentRunSession({
    required this.id,
    required this.conversationId,
    required this.origin,
    int stepsPerLoop = 12,
    int maxLoops = 2,
    this.loopMode = AgentLoopMode.ask,
    this.maxDuration = const Duration(minutes: 3),
  }) : startedAt = DateTime.now() {
    this.stepsPerLoop = stepsPerLoop.clamp(
      AgentExecutionConfig.minStepsPerLoop,
      AgentExecutionConfig.maxStepsPerLoop,
    );
    this.maxLoops = maxLoops.clamp(
      AgentExecutionConfig.minLoops,
      AgentExecutionConfig.maxLoopsAllowed,
    );
    hardIterationLimit = this.stepsPerLoop * effectiveMaxLoops;
    iterationLimit = this.stepsPerLoop;
  }

  final String id;
  final int conversationId;
  final ExecutionOrigin origin;
  late final int stepsPerLoop;
  late final int maxLoops;
  final AgentLoopMode loopMode;
  late final int hardIterationLimit;
  final Duration maxDuration;
  final DateTime startedAt;
  final AgentCancellationToken cancellation = AgentCancellationToken();

  AgentRunState state = AgentRunState.idle;
  int iterations = 0;
  late int iterationLimit;

  int get effectiveMaxLoops => loopMode == AgentLoopMode.single ? 1 : maxLoops;
  int get currentLoop => (iterationLimit / stepsPerLoop).ceil();
  int get proposedLoop => (currentLoop + 1).clamp(1, effectiveMaxLoops);

  bool get expired => DateTime.now().difference(startedAt) >= maxDuration;
  Duration get remainingDuration {
    final remaining = maxDuration - DateTime.now().difference(startedAt);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get canContinue =>
      !cancellation.isCancelled &&
      !expired &&
      iterations < iterationLimit &&
      iterations < hardIterationLimit;
  bool get canExtendBudget =>
      !cancellation.isCancelled &&
      !expired &&
      iterationLimit < hardIterationLimit;
  int get proposedIterationLimit =>
      (iterationLimit + stepsPerLoop).clamp(iterationLimit, hardIterationLimit);

  void transition(AgentRunState next) {
    if (_terminalStates.contains(state)) return;
    state = next;
  }

  void beginIteration() {
    cancellation.throwIfCancelled();
    if (expired) {
      throw TimeoutException('Agent run exceeded ${maxDuration.inSeconds}s');
    }
    if (iterations >= iterationLimit || iterations >= hardIterationLimit) {
      throw AgentBudgetExceededException(iterations);
    }
    iterations++;
  }

  void extendBudget() {
    if (!canExtendBudget) return;
    iterationLimit = proposedIterationLimit;
  }

  void cancel() {
    cancellation.cancel();
    state = AgentRunState.cancelled;
  }

  static const _terminalStates = {
    AgentRunState.completed,
    AgentRunState.cancelled,
    AgentRunState.failed,
  };
}

class AgentBudgetRequest {
  const AgentBudgetRequest({
    required this.usedIterations,
    required this.currentLimit,
    required this.proposedLimit,
    required this.hardLimit,
    required this.stepsPerLoop,
    required this.currentLoop,
    required this.proposedLoop,
    required this.maxLoops,
  });

  final int usedIterations;
  final int currentLimit;
  final int proposedLimit;
  final int hardLimit;
  final int stepsPerLoop;
  final int currentLoop;
  final int proposedLoop;
  final int maxLoops;
}

class AgentBudgetExceededException implements Exception {
  const AgentBudgetExceededException(this.iterations);
  final int iterations;
  @override
  String toString() =>
      'Agent tool budget exhausted after $iterations iterations';
}
