/// Solvhen — 个人设置：主动消息与 Android 后台调度。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/database_service.dart' as dbs;
import '../services/proactive_service.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';

class SettingsProfilePage extends ConsumerStatefulWidget {
  const SettingsProfilePage({super.key});

  @override
  ConsumerState<SettingsProfilePage> createState() =>
      _SettingsProfilePageState();
}

class _SettingsProfilePageState extends ConsumerState<SettingsProfilePage> {
  final _intervalController = TextEditingController(text: '30');
  final _scrollController = ScrollController();
  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;
  int _minutes = 30;
  String _scheduleMode = 'disabled';
  String? _lastTick;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await dbs.DB.getConfig();
    final minutes = (int.tryParse(config['proactive_interval'] ?? '30') ?? 30)
        .clamp(1, 1440);
    if (!mounted) return;
    setState(() {
      _enabled = config['proactive_enabled'] == 'true';
      _minutes = minutes;
      _intervalController.text = '$minutes';
      _scheduleMode = config['proactive_schedule_mode'] ??
          (_enabled
              ? (minutes < 15 ? 'foreground_service' : 'workmanager')
              : 'disabled');
      _lastTick = config['last_proactive_tick'];
      final error = config['last_proactive_error'];
      _lastError = error == null || error.isEmpty ? null : error;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  Future<bool> _confirmHighFrequency() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('开启高频前台服务？'),
            content: const Text(
              '1–14 分钟无法使用 Android 普通后台周期任务。Solvhen 将启动真正的前台服务并显示不可隐藏的常驻通知，同时保持 CPU 唤醒，耗电会明显增加。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('改用 15 分钟以上'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('显式开启'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _ensureNotificationPermission() async {
    var status = await Permission.notification.status;
    if (!status.isGranted) status = await Permission.notification.request();
    if (status.isGranted) return true;
    _message('没有通知权限，主动消息和前台服务无法安全运行', error: true);
    return false;
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    if (value && _minutes < 15 && !await _confirmHighFrequency()) return;
    if (value && !await _ensureNotificationPermission()) return;
    setState(() => _busy = true);
    try {
      if (value) {
        await startProactive(intervalMinutes: _minutes);
      } else {
        await stopProactive();
      }
      if (!mounted) return;
      setState(() => _enabled = value);
      await _refreshRuntime();
    } catch (error) {
      if (!mounted) return;
      setState(() => _enabled = false);
      _message('主动消息启动失败：${error.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyMinutes(int requested) async {
    if (_busy) return;
    final minutes = requested.clamp(1, 1440);
    if (_enabled && minutes < 15 && _minutes >= 15) {
      if (!await _confirmHighFrequency()) {
        _intervalController.text = '$_minutes';
        return;
      }
    }
    setState(() => _busy = true);
    try {
      if (_enabled) {
        await startProactive(
          intervalMinutes: minutes,
          sendImmediately: false,
        );
      } else {
        await dbs.DB.setConfig('proactive_interval', '$minutes');
      }
      if (!mounted) return;
      setState(() {
        _minutes = minutes;
        _intervalController.text = '$minutes';
      });
      await _refreshRuntime();
    } catch (error) {
      _message('调度更新失败：${error.runtimeType}', error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshRuntime() async {
    final config = await dbs.DB.getConfig();
    if (!mounted) return;
    setState(() {
      _scheduleMode = config['proactive_schedule_mode'] ?? 'disabled';
      _lastTick = config['last_proactive_tick'];
      final error = config['last_proactive_error'];
      _lastError = error == null || error.isEmpty ? null : error;
    });
  }

  void _message(String text, {bool error = false}) {
    if (!mounted) return;
    final colors = ThemeColors(ref.read(themeProvider));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? colors.danger : null,
      ),
    );
  }

  String get _intervalLabel {
    if (_minutes < 60) return '$_minutes 分钟';
    final hours = _minutes ~/ 60;
    final remainder = _minutes % 60;
    return remainder == 0 ? '$hours 小时' : '$hours 小时 $remainder 分钟';
  }

  String get _modeTitle => switch (_scheduleMode) {
        'foreground_service' => '前台服务',
        'workmanager' => 'WorkManager',
        'foreground_timer' => '前台 Timer',
        'failed' => '调度失败',
        _ => '已停止',
      };

  String get _modeDetail => switch (_scheduleMode) {
        'foreground_service' => '1–14 分钟 · 常驻通知 · 较高耗电',
        'workmanager' => '后台由系统调度；应用前台时 Timer 辅助并原子去重',
        'foreground_timer' => '当前平台仅在应用前台运行',
        'failed' => '已自动回滚为关闭状态',
        _ => '不会在后台唤醒或发送消息',
      };

  @override
  void dispose() {
    _intervalController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(title: const Text('个人设置')),
      body: Stack(
        children: [
          Positioned.fill(child: SolvhenDotField(color: colors.dotColor)),
          if (_loading)
            Center(child: CircularProgressIndicator(color: colors.accent))
          else
            ListView(
              controller: _scrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
              children: [
                _switchPanel(colors),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '自由间隔'),
                _intervalPanel(colors),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '运行状态'),
                _runtimePanel(colors),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '调度规则'),
                SolvhenPanel(
                  colors: colors,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _rule(colors, '01', '应用在前台', '使用 Timer；与后台任务通过数据库原子去重'),
                      _rule(colors, '15+', '后台标准周期',
                          '15–1440 分钟交给 Android WorkManager，系统可因省电延迟'),
                      _rule(colors, '01–14', '高频周期', '必须显式开启前台服务，并持续显示常驻通知'),
                      _rule(colors, 'SAFE', '崩溃恢复', '已领取但未完成的主动任务不会自动重放'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _switchPanel(ThemeColors colors) {
    final statusColor = _enabled ? colors.accent : colors.textTertiary;
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: statusColor.withValues(alpha: 0.22)),
            ),
            child:
                Icon(Icons.notifications_active_outlined, color: statusColor),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _enabled ? '主动消息已开启' : '主动消息已关闭',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _enabled ? '当前间隔 $_intervalLabel' : '默认不在后台运行，无自动遥测',
                  style: TextStyle(color: colors.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_busy)
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          else
            Switch(value: _enabled, onChanged: _toggle),
        ],
      ),
    );
  }

  Widget _intervalPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _intervalController,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '间隔分钟数',
                      suffixText: 'MIN',
                      prefixIcon: Icon(Icons.schedule_rounded),
                    ),
                    onSubmitted: (value) =>
                        _applyMinutes(int.tryParse(value) ?? _minutes),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _applyMinutes(
                            int.tryParse(_intervalController.text) ?? _minutes,
                          ),
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [5, 15, 30, 60, 240, 1440]
                  .map((value) => ChoiceChip(
                        label:
                            Text(value < 60 ? '$value 分' : '${value ~/ 60} 小时'),
                        selected: _minutes == value,
                        onSelected: _busy ? null : (_) => _applyMinutes(value),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SolvhenTag(
                  colors: colors,
                  label: _minutes < 15 ? 'FG SERVICE' : 'WORKMANAGER',
                  color: _minutes < 15 ? colors.warning : colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '可自由设置 1–1440 分钟，越短越耗电。',
                    style: TextStyle(color: colors.textTertiary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _runtimePanel(ThemeColors colors) {
    final ok = _enabled && _scheduleMode != 'failed';
    final statusColor = ok ? colors.success : colors.textTertiary;
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _modeTitle,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _refreshRuntime,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          Text(
            _modeDetail,
            style: TextStyle(
                color: colors.textTertiary, fontSize: 12, height: 1.4),
          ),
          if (_lastTick != null) ...[
            const SizedBox(height: 10),
            Text(
              'LAST TICK  ·  ${_formatTimestamp(_lastTick!)}',
              style: TextStyle(
                color: colors.navy,
                fontFamily: 'monospace',
                fontSize: 11,
                letterSpacing: 0.5,
              ),
            ),
          ],
          if (_lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              'ERROR  ·  $_lastError',
              style: TextStyle(color: colors.danger, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTimestamp(String raw) {
    final value = DateTime.tryParse(raw)?.toLocal();
    if (value == null) return '—';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.month}/${value.day} ${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  Widget _rule(
    ThemeColors colors,
    String code,
    String title,
    String detail,
  ) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 42,
              child: Text(
                code,
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
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
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
