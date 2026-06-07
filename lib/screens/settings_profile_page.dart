/// Solvhen — 个人设置页面：主动消息开关 + 间隔 + 其他个人偏好
library;

import 'package:flutter/material.dart';
import '../services/database_service.dart' as dbs;
import '../services/proactive_service.dart';

class SettingsProfilePage extends StatefulWidget {
  const SettingsProfilePage({super.key});
  @override
  State<SettingsProfilePage> createState() => _SettingsProfilePageState();
}

class _SettingsProfilePageState extends State<SettingsProfilePage> {
  bool _proactiveEnabled = false;
  double _intervalMinutes = 30;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await dbs.DB.getConfig();
    setState(() {
      _proactiveEnabled = cfg['proactive_enabled'] == 'true';
      _intervalMinutes = double.tryParse(cfg['proactive_interval'] ?? '30') ?? 30;
      _loading = false;
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _proactiveEnabled = v);
    await dbs.DB.setConfig('proactive_enabled', v ? 'true' : 'false');
    if (v) {
      await dbs.DB.setConfig('proactive_interval', _intervalMinutes.round().toString());
      await ProactiveService().start();
    } else {
      await ProactiveService().stop();
    }
  }

  Future<void> _setInterval(double v) async {
    final minutes = v.round().clamp(1, 1440);
    setState(() => _intervalMinutes = minutes.toDouble());
    await dbs.DB.setConfig('proactive_interval', minutes.toString());
    if (_proactiveEnabled) {
      await ProactiveService().stop();
      await ProactiveService().start();
    }
  }

  String _intervalLabel(double v) {
    final m = v.round();
    if (m < 60) return '${m}分钟';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem > 0 ? '${h}小时${rem}分钟' : '${h}小时';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E);
    final cs = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF98989E) : const Color(0xFF6E6E73);
    final cardBg = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1C1C1E) : Colors.white;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0D0D12) : const Color(0xFFF2F2F7),
      appBar: AppBar(
        title: const Text('个人设置'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 主动消息 ──
                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(children: [
                        Icon(Icons.notifications_active_rounded, size: 22, color: c),
                        const SizedBox(width: 10),
                        Text('主动消息', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c)),
                        const Spacer(),
                        Switch(
                          value: _proactiveEnabled,
                          onChanged: _toggle,
                          activeColor: const Color(0xFF4dc9f6),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        '开启后 Solvhen 会定时主动发消息给你',
                        style: TextStyle(fontSize: 13, color: cs),
                      ),

                      // Interval slider (only when enabled)
                      if (_proactiveEnabled) ...[
                        const SizedBox(height: 20),
                        Row(children: [
                          Text('间隔', style: TextStyle(fontSize: 15, color: c)),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4dc9f6).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _intervalLabel(_intervalMinutes),
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF4dc9f6)),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Slider(
                          value: _intervalMinutes,
                          min: 1,
                          max: 240,
                          divisions: 239,
                          activeColor: const Color(0xFF4dc9f6),
                          onChanged: _setInterval,
                        ),
                        Row(children: [
                          Text('1分', style: TextStyle(fontSize: 11, color: cs)),
                          const Spacer(),
                          Text('4小时', style: TextStyle(fontSize: 11, color: cs)),
                        ]),
                        const SizedBox(height: 12),
                        // Status indicator
                        Row(children: [
                          Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                              color: ProactiveService().isRunning ? const Color(0xFF34C759) : const Color(0xFFFF9500),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            ProactiveService().isRunning ? '运行中' : '等待启动…',
                            style: TextStyle(fontSize: 13, color: cs),
                          ),
                        ]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
