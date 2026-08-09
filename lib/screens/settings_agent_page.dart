import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/agent/agent_execution_config.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';

class SettingsAgentPage extends ConsumerStatefulWidget {
  const SettingsAgentPage({super.key});

  @override
  ConsumerState<SettingsAgentPage> createState() => _SettingsAgentPageState();
}

class _SettingsAgentPageState extends ConsumerState<SettingsAgentPage> {
  AgentExecutionConfig _config = const AgentExecutionConfig();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await AgentExecutionConfig.load();
      if (mounted) setState(() => _config = config);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_config.loopMode == AgentLoopMode.automatic &&
        _config.maximumToolSteps > 200) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('保存高预算自动循环？'),
          content: Text(
            '当前配置最多执行 ${_config.maximumToolSteps} 个工具步骤，'
            '并会自动跨轮继续。这可能产生较高模型费用和设备操作次数。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回调整'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => _saving = true);
    try {
      await _config.save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Agent 运行设置已保存，下次发送消息生效'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败：$error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    setState(() => _config = const AgentExecutionConfig());
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(
        title: const Text('Agent 运行'),
        actions: [
          TextButton(
              onPressed: _loading || _saving ? null : _reset,
              child: const Text('恢复默认')),
          const SizedBox(width: 6),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, color: colors.separator),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: SolvhenDotField(color: colors.dotColor)),
          if (_loading)
            Center(child: CircularProgressIndicator(color: colors.accent))
          else
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              children: [
                _overview(colors),
                const SizedBox(height: 22),
                _section(colors, '预算结构', 'STEPS × LOOPS'),
                const SizedBox(height: 10),
                SolvhenPanel(
                  colors: colors,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      _NumberSetting(
                        key: ValueKey('steps_${_config.stepsPerLoop}'),
                        colors: colors,
                        icon: Icons.linear_scale_rounded,
                        title: '每轮步数',
                        detail: '一轮内最多执行的工具调用次数',
                        value: _config.stepsPerLoop,
                        min: AgentExecutionConfig.minStepsPerLoop,
                        max: AgentExecutionConfig.maxStepsPerLoop,
                        suffix: '步',
                        onChanged: (value) => setState(() =>
                            _config = _config.copyWith(stepsPerLoop: value)),
                      ),
                      _divider(colors),
                      _NumberSetting(
                        key: ValueKey('loops_${_config.maxLoops}'),
                        colors: colors,
                        icon: Icons.loop_rounded,
                        title: '最大循环',
                        detail: _config.loopMode == AgentLoopMode.single
                            ? '仅单轮模式下暂不使用此数值'
                            : '最多允许进入多少个步骤区块',
                        value: _config.maxLoops,
                        min: AgentExecutionConfig.minLoops,
                        max: AgentExecutionConfig.maxLoopsAllowed,
                        suffix: '轮',
                        enabled: _config.loopMode != AgentLoopMode.single,
                        onChanged: (value) => setState(
                            () => _config = _config.copyWith(maxLoops: value)),
                      ),
                      _divider(colors),
                      _NumberSetting(
                        key: ValueKey('timeout_${_config.timeoutMinutes}'),
                        colors: colors,
                        icon: Icons.timer_outlined,
                        title: '运行时长',
                        detail: '整次请求的硬截止时间，包含等待和工具执行',
                        value: _config.timeoutMinutes,
                        min: AgentExecutionConfig.minTimeoutMinutes,
                        max: AgentExecutionConfig.maxTimeoutMinutes,
                        suffix: '分',
                        onChanged: (value) => setState(() =>
                            _config = _config.copyWith(timeoutMinutes: value)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _section(colors, '循环策略', 'LOOP POLICY'),
                const SizedBox(height: 10),
                ...AgentLoopMode.values.map((mode) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _modeCard(colors, mode),
                    )),
                const SizedBox(height: 14),
                _executionPreview(colors),
                const SizedBox(height: 18),
                _riskNotice(colors),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.save_outlined, size: 19),
                    label: Text(_saving ? '正在保存' : '保存运行设置'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _overview(ThemeColors colors) {
    final tone = _riskColor(colors);
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(18),
      borderColor: tone.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.route_rounded, color: tone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '理论最多 ${_config.maximumToolSteps} 步',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_config.stepsPerLoop} 步 × ${_config.effectiveLoops} 轮 '
                      '· ${_config.timeoutMinutes} 分钟',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              SolvhenTag(
                colors: colors,
                label: _config.loopMode.label,
                color: tone,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 5,
              value: (_config.maximumToolSteps / 1000).clamp(0.02, 1.0),
              color: tone,
              backgroundColor: colors.separator,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '步数是预算上限，不代表每次都会全部用完。模型完成任务后可提前结束。',
            style: TextStyle(
                color: colors.textTertiary, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _modeCard(ThemeColors colors, AgentLoopMode mode) {
    final selected = _config.loopMode == mode;
    final tone =
        mode == AgentLoopMode.automatic ? colors.warning : colors.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _config = _config.copyWith(loopMode: mode)),
        borderRadius: BorderRadius.circular(18),
        child: SolvhenPanel(
          colors: colors,
          showShadow: selected,
          borderColor:
              selected ? tone.withValues(alpha: 0.42) : colors.separator,
          backgroundColor:
              selected ? tone.withValues(alpha: 0.055) : colors.bgCard,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? tone : Colors.transparent,
                  border: Border.all(
                    color: selected ? tone : colors.textPlaceholder,
                    width: 2,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 13, color: colors.bgCard)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      mode.description,
                      style:
                          TextStyle(color: colors.textTertiary, fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (mode == AgentLoopMode.automatic)
                SolvhenTag(
                  colors: colors,
                  label: 'HIGH AUTONOMY',
                  color: colors.warning,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _executionPreview(ThemeColors colors) {
    final loops = _config.effectiveLoops;
    final shown = loops.clamp(1, 5);
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schema_outlined, color: colors.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                '执行预览',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                'FINITE LOOP',
                style: TextStyle(
                  color: colors.textPlaceholder,
                  fontFamily: 'monospace',
                  fontSize: 8,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (var index = 0; index < shown; index++) ...[
                Expanded(
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: colors.accentFaint,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: colors.separator),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: colors.navy,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '${_config.stepsPerLoop}步',
                          style: TextStyle(
                              color: colors.textTertiary, fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                ),
                if (index != shown - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Icon(Icons.chevron_right_rounded,
                        color: colors.textPlaceholder, size: 14),
                  ),
              ],
              if (loops > shown) ...[
                const SizedBox(width: 6),
                Text(
                  '+${loops - shown}',
                  style: TextStyle(
                    color: colors.accent,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _riskNotice(ThemeColors colors) {
    final high = _config.maximumToolSteps > 200 ||
        _config.loopMode == AgentLoopMode.automatic;
    final tone = high ? colors.warning : colors.success;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: tone.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            high ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
            color: tone,
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              high
                  ? '高步数或自动循环可能增加模型费用。发送、删除、安装、锁屏和系统设置仍然逐次确认。'
                  : '当前预算较克制。任何循环策略都不能绕过能力开关、来源隔离和不可逆操作确认。',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 10,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _riskColor(ThemeColors colors) {
    if (_config.maximumToolSteps > 200 ||
        _config.loopMode == AgentLoopMode.automatic) {
      return colors.warning;
    }
    return colors.success;
  }

  Widget _section(ThemeColors colors, String label, String trailing) =>
      SolvhenSectionLabel(
        colors: colors,
        label: label,
        trailing: Text(
          trailing,
          style: TextStyle(
            color: colors.textPlaceholder,
            fontFamily: 'monospace',
            fontSize: 9,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _divider(ThemeColors colors) => Padding(
        padding: const EdgeInsets.only(left: 56),
        child: Divider(height: 1, color: colors.separator),
      );
}

class _NumberSetting extends StatefulWidget {
  const _NumberSetting({
    super.key,
    required this.colors,
    required this.icon,
    required this.title,
    required this.detail,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    this.enabled = true,
  });

  final ThemeColors colors;
  final IconData icon;
  final String title;
  final String detail;
  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  State<_NumberSetting> createState() => _NumberSettingState();
}

class _NumberSettingState extends State<_NumberSetting> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
    _focus = FocusNode();
    _focus.addListener(_commitOnBlur);
  }

  @override
  void didUpdateWidget(_NumberSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && oldWidget.value != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  void _commitOnBlur() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text) ?? widget.value;
    final value = parsed.clamp(widget.min, widget.max);
    _controller.text = '$value';
    widget.onChanged(value);
  }

  void _step(int delta) {
    if (!widget.enabled) return;
    final value = (widget.value + delta).clamp(widget.min, widget.max);
    _controller.text = '$value';
    widget.onChanged(value);
  }

  @override
  void dispose() {
    _focus.removeListener(_commitOnBlur);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final opacity = widget.enabled ? 1.0 : 0.45;
    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
        child: Row(
          children: [
            Container(
              width: 35,
              height: 35,
              decoration: BoxDecoration(
                color: colors.accentSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(widget.icon, color: colors.accent, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.detail,
                    style: TextStyle(color: colors.textTertiary, fontSize: 9),
                  ),
                ],
              ),
            ),
            _stepButton(colors, Icons.remove_rounded, () => _step(-1)),
            Container(
              width: 57,
              height: 36,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: colors.bgRoot,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.separator),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      enabled: widget.enabled,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onSubmitted: (_) => _commit(),
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text(
                      widget.suffix,
                      style:
                          TextStyle(color: colors.textPlaceholder, fontSize: 8),
                    ),
                  ),
                ],
              ),
            ),
            _stepButton(colors, Icons.add_rounded, () => _step(1)),
          ],
        ),
      ),
    );
  }

  Widget _stepButton(ThemeColors colors, IconData icon, VoidCallback onTap) =>
      Material(
        color: colors.accentFaint,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: widget.enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 33,
            height: 36,
            child: Icon(icon, size: 17, color: colors.textSecondary),
          ),
        ),
      );
}
