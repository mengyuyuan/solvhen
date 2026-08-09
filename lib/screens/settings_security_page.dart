import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security/tool_security.dart';
import '../core/agent/agent_execution_config.dart';
import '../services/database_service.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';
import '../tools/tool_registry.dart';

class SettingsSecurityPage extends ConsumerStatefulWidget {
  const SettingsSecurityPage({super.key});

  @override
  ConsumerState<SettingsSecurityPage> createState() =>
      _SettingsSecurityPageState();
}

class _SettingsSecurityPageState extends ConsumerState<SettingsSecurityPage> {
  StreamSubscription<bool>? _subscription;
  Map<String, bool> _permissions = const {};
  List<Map<String, dynamic>> _audits = const [];
  List<Map<String, dynamic>> _runs = const [];
  String _auditFilter = 'all';
  bool _loading = true;
  bool _exporting = false;

  static const _capabilityOrder = [
    'system',
    'file',
    'web',
    'memory',
    'history',
    'ui',
    'theme',
    'code',
    'delegation',
    'dynamic',
  ];

  static const _capabilitySpecs = <String, _CapabilitySpec>{
    'system': _CapabilitySpec(
      '设备与系统',
      '设备状态、应用控制、模型切换与主动任务',
      Icons.phone_android_rounded,
    ),
    'file': _CapabilitySpec(
      '本地文件',
      '应用沙盒内的文件读取、写入和删除',
      Icons.folder_outlined,
    ),
    'web': _CapabilitySpec(
      '网络访问',
      '网页搜索、抓取和远程内容读取',
      Icons.language_rounded,
    ),
    'memory': _CapabilitySpec(
      '长期记忆',
      '搜索、保存和关联本地记忆',
      Icons.psychology_alt_outlined,
    ),
    'history': _CapabilitySpec(
      '对话历史',
      '只读检索本机历史对话',
      Icons.manage_search_rounded,
    ),
    'ui': _CapabilitySpec(
      '界面画布',
      '渲染卡片、动画和交互式内容',
      Icons.dashboard_customize_outlined,
    ),
    'theme': _CapabilitySpec(
      '外观控制',
      '调整主题、气泡颜色和显示模式',
      Icons.palette_outlined,
    ),
    'code': _CapabilitySpec(
      '动态工具',
      '注册受限工具和运行开发能力',
      Icons.code_rounded,
    ),
    'delegation': _CapabilitySpec(
      '子 Agent',
      '向受限白名单子任务进行委派',
      Icons.hub_outlined,
    ),
    'dynamic': _CapabilitySpec(
      '已注册扩展',
      '运行本机动态注册的扩展工具',
      Icons.extension_outlined,
    ),
  };

  @override
  void initState() {
    super.initState();
    _subscription = SecuritySession.instance.changes.listen((_) {
      if (mounted) {
        setState(() {
          _permissions = SecuritySession.instance.capabilityPermissions;
        });
      }
    });
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait<dynamic>([
        DB.getToolPermissions(),
        DB.getRecentToolAudits(limit: 50),
        DB.getRecentAgentRuns(limit: 30),
      ]);
      final permissions = results[0] as Map<String, bool>;
      SecuritySession.instance.hydratePermissions(permissions);
      if (!mounted) return;
      setState(() {
        _permissions = permissions;
        _audits = results[1] as List<Map<String, dynamic>>;
        _runs = results[2] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('安全数据读取失败：$error', error: true);
    }
  }

  Future<void> _setTrusted(bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启本次运行信任模式？'),
          content: const Text(
            '普通修改操作将自动执行。发送、删除、安装、锁屏和系统设置仍会逐次确认；应用重启后自动关闭。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仅本次开启'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    SecuritySession.instance.setTrusted(enabled);
  }

  Future<void> _setCapability(String capability, bool allowed) async {
    final previous = SecuritySession.instance.isCapabilityAllowed(capability);
    SecuritySession.instance.setCapabilityAllowed(capability, allowed);
    try {
      await DB.setToolPermission(capability, granted: allowed);
      if (mounted) {
        setState(() {
          _permissions = SecuritySession.instance.capabilityPermissions;
        });
      }
    } catch (error) {
      SecuritySession.instance.setCapabilityAllowed(capability, previous);
      _showMessage('权限保存失败：$error', error: true);
    }
  }

  Future<void> _clearAudits() async {
    if (_audits.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本地审计日志？'),
        content: const Text('此操作不可撤销，但不会删除对话、记忆或设置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DB.clearToolAudits();
    if (mounted) {
      setState(() => _audits = const []);
      _showMessage('本地工具审计日志已清除');
    }
  }

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final execution = await AgentExecutionConfig.load();
      final bundle = <String, dynamic>{
        'format': 'solvhen-diagnostics-v1',
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'database_schema': DB.schemaVersion,
        'security': {
          'trusted_for_current_process': SecuritySession.instance.trusted,
          'capability_permissions': _permissions,
        },
        'agent_execution': {
          'steps_per_loop': execution.stepsPerLoop,
          'max_loops': execution.maxLoops,
          'effective_loops': execution.effectiveLoops,
          'loop_mode': execution.loopMode.storageValue,
          'timeout_minutes': execution.timeoutMinutes,
          'maximum_tool_steps': execution.maximumToolSteps,
        },
        'agent_runs': _runs.map(_safeRun).toList(),
        'tool_audits': _audits.map(_safeAudit).toList(),
        'privacy': {
          'messages_included': false,
          'secrets_included': false,
          'paths_included': false,
          'audit_arguments_are_redacted': true,
        },
      };
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出 Solvhen 诊断包',
        fileName: 'solvhen-diagnostics-$stamp.json',
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(bundle)),
        ),
      );
      if (path != null) _showMessage('诊断包已由你保存');
    } catch (error) {
      _showMessage('诊断包导出失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Map<String, dynamic> _safeRun(Map<String, dynamic> row) => {
        'origin': row['origin'],
        'status': row['status'],
        'iteration_count': row['iteration_count'],
        'started_at': row['started_at'],
        'finished_at': row['finished_at'],
        'error_code': row['error_code'],
      };

  Map<String, dynamic> _safeAudit(Map<String, dynamic> row) => {
        'origin': row['origin'],
        'tool_name': row['tool_name'],
        'risk': row['risk'],
        'arguments_redacted': row['arguments_redacted'],
        'decision': row['decision'],
        'status': row['status'],
        'started_at': row['started_at'],
        'finished_at': row['finished_at'],
        'error_code': row['error_code'],
      };

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final colors = ThemeColors(ref.read(themeProvider));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? colors.danger : colors.textPrimary,
      ),
    );
  }

  List<String> get _capabilities {
    final registry = ToolRegistry();
    final discovered = registry.names
        .expand(
            (name) => registry[name]?.effectiveCapabilities ?? const <String>{})
        .toSet();
    return [
      ..._capabilityOrder.where(discovered.contains),
      ...discovered.where((item) => !_capabilityOrder.contains(item)).toList()
        ..sort(),
    ];
  }

  int _toolCount(String capability) {
    final registry = ToolRegistry();
    return registry.names
        .where((name) =>
            registry[name]?.effectiveCapabilities.contains(capability) ?? false)
        .length;
  }

  List<Map<String, dynamic>> get _filteredAudits {
    if (_auditFilter == 'all') return _audits;
    if (_auditFilter == 'completed') {
      return _audits.where((row) => row['status'] == 'completed').toList();
    }
    return _audits.where((row) => row['status'] != 'completed').toList();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    final trusted = SecuritySession.instance.trusted;
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(
        title: const Text('安全中心'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
          ),
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
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 34),
              children: [
                _securityModeCard(colors, trusted),
                const SizedBox(height: 22),
                _runOverview(colors),
                const SizedBox(height: 22),
                _sectionHeader(colors, '能力开关', 'CAPABILITY GATE'),
                const SizedBox(height: 7),
                Text(
                  '关闭后会从模型工具清单中隐藏，并在实际执行入口再次拦截。',
                  style: TextStyle(color: colors.textTertiary, fontSize: 11),
                ),
                const SizedBox(height: 10),
                _capabilityPanel(colors),
                const SizedBox(height: 22),
                _sectionHeader(colors, '来源隔离', 'ORIGIN POLICY'),
                const SizedBox(height: 10),
                _originPanel(colors),
                const SizedBox(height: 22),
                _auditSection(colors),
                const SizedBox(height: 14),
                _diagnosticCard(colors),
              ],
            ),
        ],
      ),
    );
  }

  Widget _securityModeCard(ThemeColors colors, bool trusted) {
    final tone = trusted ? colors.warning : colors.success;
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(18),
      borderColor: tone.withValues(alpha: 0.38),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusIcon(
                colors: colors,
                icon: trusted
                    ? Icons.shield_rounded
                    : Icons.verified_user_outlined,
                tone: tone,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trusted ? '信任模式运行中' : '安全模式运行中',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      trusted ? '普通修改自动执行 · 重启后失效' : '只读自动执行 · 修改前询问',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: trusted,
                onChanged: _setTrusted,
                activeThumbColor: colors.warning,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: colors.separator),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SolvhenTag(
                colors: colors,
                label: '仅当前进程',
                color: colors.accent,
                icon: Icons.timer_outlined,
              ),
              SolvhenTag(
                colors: colors,
                label: '不可逆操作总是确认',
                color: colors.warning,
                icon: Icons.priority_high_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _runOverview(ThemeColors colors) {
    final completed = _runs.where((row) => row['status'] == 'completed').length;
    final interrupted = _runs
        .where((row) => const {'cancelled', 'failed'}.contains(row['status']))
        .length;
    final iterations = _runs.fold<int>(
      0,
      (sum, row) => sum + (row['iteration_count'] as int? ?? 0),
    );
    return Column(
      children: [
        _sectionHeader(colors, '运行概览', 'LAST ${_runs.length} RUNS'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                colors,
                value: '${_runs.length}',
                label: '最近运行',
                icon: Icons.timeline_rounded,
                tone: colors.accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _metricCard(
                colors,
                value: '$completed',
                label: '已完成',
                icon: Icons.check_circle_outline_rounded,
                tone: colors.success,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _metricCard(
                colors,
                value: '$interrupted',
                label: '中止/失败',
                icon: Icons.pause_circle_outline_rounded,
                tone: interrupted > 0 ? colors.warning : colors.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '累计工具轮次 $iterations',
            style: TextStyle(
              color: colors.textPlaceholder,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ),
      ],
    );
  }

  Widget _metricCard(
    ThemeColors colors, {
    required String value,
    required String label,
    required IconData icon,
    required Color tone,
  }) {
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: tone),
          const SizedBox(height: 9),
          Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(color: colors.textTertiary, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _capabilityPanel(ThemeColors colors) {
    final capabilities = _capabilities;
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (var index = 0; index < capabilities.length; index++) ...[
            _capabilityRow(colors, capabilities[index]),
            if (index != capabilities.length - 1)
              Padding(
                padding: const EdgeInsets.only(left: 56),
                child: Divider(height: 1, color: colors.separator),
              ),
          ],
        ],
      ),
    );
  }

  Widget _capabilityRow(ThemeColors colors, String capability) {
    final spec = _capabilitySpecs[capability] ??
        _CapabilitySpec(
          capability,
          '由已注册工具声明的能力',
          Icons.tune_rounded,
        );
    final allowed = _permissions[capability] ?? true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
      child: Row(
        children: [
          _statusIcon(
            colors: colors,
            icon: spec.icon,
            tone: allowed ? colors.accent : colors.textPlaceholder,
            size: 35,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        spec.label,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '${_toolCount(capability)} TOOLS',
                      style: TextStyle(
                        color: colors.textPlaceholder,
                        fontFamily: 'monospace',
                        fontSize: 8,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  spec.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textTertiary, fontSize: 10),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: allowed,
            onChanged: (value) => _setCapability(capability, value),
          ),
        ],
      ),
    );
  }

  Widget _originPanel(ThemeColors colors) {
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        children: [
          _originRow(
            colors,
            icon: Icons.person_outline_rounded,
            title: '本地对话',
            detail: '按安全模式与能力开关执行',
            tag: '完整能力',
          ),
          _originRow(
            colors,
            icon: Icons.lan_outlined,
            title: 'OneBot',
            detail: '当前消息回复、网络查询和安全只读',
            tag: '严格限制',
          ),
          _originRow(
            colors,
            icon: Icons.schedule_outlined,
            title: '主动任务',
            detail: '只读、记忆和本地通知',
            tag: '只读优先',
          ),
          _originRow(
            colors,
            icon: Icons.hub_outlined,
            title: '子 Agent',
            detail: '显式白名单，禁止递归委派',
            tag: '白名单',
            showDivider: false,
          ),
        ],
      ),
    );
  }

  Widget _auditSection(ThemeColors colors) {
    final filtered = _filteredAudits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(colors, '工具审计', 'LOCAL · 7 DAYS'),
        const SizedBox(height: 10),
        Row(
          children: [
            _filterChip(colors, 'all', '全部 ${_audits.length}'),
            const SizedBox(width: 7),
            _filterChip(colors, 'completed', '完成'),
            const SizedBox(width: 7),
            _filterChip(colors, 'attention', '异常'),
            const Spacer(),
            IconButton.outlined(
              onPressed: _clearAudits,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              tooltip: '清除审计日志',
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          SolvhenPanel(
            colors: colors,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      color: colors.textPlaceholder,
                      size: 25,
                    ),
                    const SizedBox(height: 7),
                    Text(
                      _audits.isEmpty ? '暂无工具执行记录' : '此筛选下没有记录',
                      style: TextStyle(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ...filtered.map((event) => _auditCard(colors, event)),
      ],
    );
  }

  Widget _filterChip(ThemeColors colors, String value, String label) {
    final selected = _auditFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _auditFilter = value),
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected ? colors.bgCard : colors.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
      selectedColor: colors.accent,
      backgroundColor: colors.bgCard,
      side: BorderSide(color: selected ? colors.accent : colors.separator),
      showCheckmark: false,
    );
  }

  Widget _diagnosticCard(ThemeColors colors) {
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _statusIcon(
            colors: colors,
            icon: Icons.inventory_2_outlined,
            tone: colors.navy,
            size: 38,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导出脱敏诊断包',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '不含消息正文、密钥和本机路径',
                  style: TextStyle(color: colors.textTertiary, fontSize: 10),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _exporting ? null : _exportDiagnostics,
            icon: _exporting
                ? const SizedBox.square(
                    dimension: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded, size: 17),
            label: const Text('导出'),
          ),
        ],
      ),
    );
  }

  Widget _originRow(
    ThemeColors colors, {
    required IconData icon,
    required String title,
    required String detail,
    required String tag,
    bool showDivider = true,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 19, color: colors.accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style:
                          TextStyle(color: colors.textTertiary, fontSize: 10),
                    ),
                  ],
                ),
              ),
              SolvhenTag(colors: colors, label: tag, color: colors.accent),
            ],
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Divider(height: 1, color: colors.separator),
          ),
      ],
    );
  }

  Widget _auditCard(ThemeColors colors, Map<String, dynamic> event) {
    final status = event['status'] as String? ?? 'unknown';
    final statusColor = switch (status) {
      'completed' => colors.success,
      'denied' => colors.danger,
      'running' => colors.accent,
      _ => colors.warning,
    };
    final statusLabel = switch (status) {
      'completed' => '完成',
      'denied' => '拒绝',
      'running' => '执行中',
      'failed' => '失败',
      _ => status,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showAuditDetail(colors, event),
        child: SolvhenPanel(
          colors: colors,
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              _statusIcon(
                colors: colors,
                icon: status == 'completed'
                    ? Icons.check_rounded
                    : status == 'running'
                        ? Icons.sync_rounded
                        : Icons.block_rounded,
                tone: statusColor,
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event['tool_name'] as String? ?? 'unknown',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${event['origin']} · ${event['risk']} · ${_formatTime(event['started_at'])}',
                      style: TextStyle(color: colors.textTertiary, fontSize: 9),
                    ),
                  ],
                ),
              ),
              SolvhenTag(
                  colors: colors, label: statusLabel, color: statusColor),
              const SizedBox(width: 3),
              Icon(Icons.chevron_right_rounded, color: colors.textPlaceholder),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAuditDetail(
    ThemeColors colors,
    Map<String, dynamic> event,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.bgCard,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.separator,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                event['tool_name'] as String? ?? 'unknown',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              _detailRow(colors, '来源', '${event['origin']}'),
              _detailRow(colors, '风险', '${event['risk']}'),
              _detailRow(colors, '决策', '${event['decision']}'),
              _detailRow(colors, '状态', '${event['status']}'),
              _detailRow(
                  colors, '时间', _formatTime(event['started_at'], full: true)),
              if (event['error_code'] != null)
                _detailRow(colors, '错误码', '${event['error_code']}'),
              const SizedBox(height: 12),
              Text(
                '脱敏参数',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.accentFaint,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: colors.separator),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    event['arguments_redacted'] as String? ?? '{}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(ThemeColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: TextStyle(color: colors.textTertiary, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: colors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeColors colors, String label, String trailing) {
    return SolvhenSectionLabel(
      label: label,
      colors: colors,
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
  }

  Widget _statusIcon({
    required ThemeColors colors,
    required IconData icon,
    required Color tone,
    required double size,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: size * 0.48, color: tone),
    );
  }

  String _formatTime(dynamic value, {bool full = false}) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '--';
    String two(int number) => number.toString().padLeft(2, '0');
    if (full) {
      return '${date.year}-${two(date.month)}-${two(date.day)} '
          '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
    }
    return '${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

class _CapabilitySpec {
  const _CapabilitySpec(this.label, this.detail, this.icon);

  final String label;
  final String detail;
  final IconData icon;
}
