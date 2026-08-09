import '../../services/database_service.dart';

enum AgentLoopMode { ask, automatic, single }

extension AgentLoopModeInfo on AgentLoopMode {
  String get storageValue => name;

  String get label => switch (this) {
        AgentLoopMode.ask => '逐轮询问',
        AgentLoopMode.automatic => '自动循环',
        AgentLoopMode.single => '仅执行一轮',
      };

  String get description => switch (this) {
        AgentLoopMode.ask => '每轮步数用完后暂停，由你决定是否继续',
        AgentLoopMode.automatic => '自动进入下一轮，直到循环数或时间上限',
        AgentLoopMode.single => '完成当前轮后停止工具，并要求模型总结',
      };
}

class AgentExecutionConfig {
  const AgentExecutionConfig({
    this.stepsPerLoop = 12,
    this.maxLoops = 2,
    this.loopMode = AgentLoopMode.ask,
    this.timeoutMinutes = 3,
  });

  static const minStepsPerLoop = 1;
  static const maxStepsPerLoop = 100;
  static const minLoops = 1;
  static const maxLoopsAllowed = 10;
  static const minTimeoutMinutes = 1;
  static const maxTimeoutMinutes = 30;

  final int stepsPerLoop;
  final int maxLoops;
  final AgentLoopMode loopMode;
  final int timeoutMinutes;

  int get effectiveLoops => loopMode == AgentLoopMode.single ? 1 : maxLoops;
  int get maximumToolSteps => stepsPerLoop * effectiveLoops;
  Duration get maxDuration => Duration(minutes: timeoutMinutes);

  AgentExecutionConfig normalized() => AgentExecutionConfig(
        stepsPerLoop: stepsPerLoop.clamp(minStepsPerLoop, maxStepsPerLoop),
        maxLoops: maxLoops.clamp(minLoops, maxLoopsAllowed),
        loopMode: loopMode,
        timeoutMinutes:
            timeoutMinutes.clamp(minTimeoutMinutes, maxTimeoutMinutes),
      );

  AgentExecutionConfig copyWith({
    int? stepsPerLoop,
    int? maxLoops,
    AgentLoopMode? loopMode,
    int? timeoutMinutes,
  }) =>
      AgentExecutionConfig(
        stepsPerLoop: stepsPerLoop ?? this.stepsPerLoop,
        maxLoops: maxLoops ?? this.maxLoops,
        loopMode: loopMode ?? this.loopMode,
        timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
      ).normalized();

  static Future<AgentExecutionConfig> load() async {
    final values = await DB.getConfig();
    final rawMode = values['agent_loop_mode'];
    final mode = AgentLoopMode.values.cast<AgentLoopMode?>().firstWhere(
              (item) => item?.storageValue == rawMode,
              orElse: () => AgentLoopMode.ask,
            ) ??
        AgentLoopMode.ask;
    return AgentExecutionConfig(
      stepsPerLoop: int.tryParse(values['agent_steps_per_loop'] ?? '') ?? 12,
      maxLoops: int.tryParse(values['agent_max_loops'] ?? '') ?? 2,
      loopMode: mode,
      timeoutMinutes: int.tryParse(values['agent_timeout_minutes'] ?? '') ?? 3,
    ).normalized();
  }

  Future<void> save() async {
    final value = normalized();
    final db = await DB.database;
    await db.transaction((txn) async {
      Future<void> write(String key, String data) => txn.rawInsert(
            'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
            [key, data],
          );
      await write('agent_steps_per_loop', value.stepsPerLoop.toString());
      await write('agent_max_loops', value.maxLoops.toString());
      await write('agent_loop_mode', value.loopMode.storageValue);
      await write('agent_timeout_minutes', value.timeoutMinutes.toString());
    });
  }
}
