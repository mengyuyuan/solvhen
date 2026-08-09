import 'dart:async';

import '../../services/database_service.dart';
import '../security/tool_security.dart';
import 'agent_execution_config.dart';
import 'agent_run.dart';

class AgentRuntime {
  AgentRunSession? _active;
  int _sequence = 0;
  Timer? _deadlineTimer;

  AgentRunSession? get active => _active;

  Future<AgentRunSession> start({
    required int conversationId,
    ExecutionOrigin origin = ExecutionOrigin.localUser,
    AgentExecutionConfig config = const AgentExecutionConfig(),
  }) async {
    if (_active != null && !_isTerminal(_active!.state)) {
      await cancel(errorCode: 'superseded');
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    final run = AgentRunSession(
      id: 'run_${now}_${_sequence++}',
      conversationId: conversationId,
      origin: origin,
      stepsPerLoop: config.stepsPerLoop,
      maxLoops: config.maxLoops,
      loopMode: config.loopMode,
      maxDuration: config.maxDuration,
    );
    run.transition(AgentRunState.planning);
    _active = run;
    await DB.startAgentRun(
      id: run.id,
      conversationId: conversationId,
      origin: origin.name,
    );
    _deadlineTimer?.cancel();
    _deadlineTimer = Timer(run.maxDuration, () {
      unawaited(cancel(errorCode: 'run_timeout'));
    });
    return run;
  }

  ToolContext toolContext({ToolApprovalCallback? approval}) {
    final run = _requireActive();
    return ToolContext(
      requestId: run.id,
      origin: run.origin,
      cancellation: run.cancellation,
      conversationId: run.conversationId,
      approval: approval,
    );
  }

  void transition(AgentRunState state) => _requireActive().transition(state);

  void beginIteration() => _requireActive().beginIteration();

  Future<void> complete() async {
    final run = _active;
    if (run == null || _isTerminal(run.state)) return;
    run.transition(AgentRunState.completed);
    _deadlineTimer?.cancel();
    await DB.finishAgentRun(
      id: run.id,
      status: run.state.name,
      iterations: run.iterations,
    );
  }

  Future<void> fail(Object error) async {
    final run = _active;
    if (run == null || _isTerminal(run.state)) return;
    run.transition(AgentRunState.failed);
    _deadlineTimer?.cancel();
    await DB.finishAgentRun(
      id: run.id,
      status: run.state.name,
      iterations: run.iterations,
      errorCode: error.runtimeType.toString(),
    );
  }

  Future<void> cancel({String errorCode = 'user_cancelled'}) async {
    final run = _active;
    if (run == null || _isTerminal(run.state)) return;
    run.cancel();
    _deadlineTimer?.cancel();
    await DB.finishAgentRun(
      id: run.id,
      status: run.state.name,
      iterations: run.iterations,
      errorCode: errorCode,
    );
  }

  AgentRunSession _requireActive() {
    final run = _active;
    if (run == null) throw StateError('No active agent run');
    return run;
  }

  bool _isTerminal(AgentRunState state) => const {
        AgentRunState.completed,
        AgentRunState.cancelled,
        AgentRunState.failed,
      }.contains(state);
}
