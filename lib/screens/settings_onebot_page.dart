/// Solvhen — OneBot 桥接设置页：启用/禁用、端口、状态
library;

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_provider.dart';
import '../services/onebot_bridge.dart';
import '../services/database_service.dart';
import 'webview_canvas.dart';

class SettingsOneBotPage extends ConsumerStatefulWidget {
  const SettingsOneBotPage({super.key});
  @override
  ConsumerState<SettingsOneBotPage> createState() => _SettingsOneBotPageState();
}

class _SettingsOneBotPageState extends ConsumerState<SettingsOneBotPage> {
  final _portCtrl = TextEditingController(text: '13579');
  bool _enabled = false;
  bool _running = false;
  int _clients = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    OneBotBridge().onStatusChange = (running, clients) {
      if (mounted) setState(() { _running = running; _clients = clients; });
    };
  }

  Future<void> _loadConfig() async {
    final cfg = await DB.getConfig();
    final enabled = cfg['onebot_enabled'] ?? 'false';
    final port = cfg['onebot_port'] ?? '13579';
    final bridge = OneBotBridge();
    if (mounted) {
      setState(() {
        _enabled = enabled == 'true';
        _portCtrl.text = port;
        _running = bridge.isRunning;
        _clients = bridge.clientCount;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await DB.setConfig('onebot_enabled', value.toString());
    if (value) {
      final port = int.tryParse(_portCtrl.text) ?? 13579;
      await DB.setConfig('onebot_port', port.toString());
      await OneBotBridge().start(port: port);
    } else {
      await OneBotBridge().stop();
    }
    if (mounted) {
      setState(() {
        _running = value ? OneBotBridge().isRunning : false;
        _clients = OneBotBridge().clientCount;
      });
    }
  }

  Future<void> _changePort() async {
    final port = int.tryParse(_portCtrl.text) ?? 13579;
    await DB.setConfig('onebot_port', port.toString());
    if (_enabled) {
      await OneBotBridge().restart(port: port);
      if (mounted) setState(() {
        _running = OneBotBridge().isRunning;
        _clients = OneBotBridge().clientCount;
      });
    }
  }

  @override
  void dispose() {
    OneBotBridge().onStatusChange = null;
    _portCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    if (_loading) {
      return Scaffold(
        backgroundColor: c.bgRoot,
        appBar: AppBar(title: Text('QQ/微信 桥接', style: TextStyle(color: c.textPrimary))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: c.bgRoot,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text('QQ/微信 桥接', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: c.textPrimary)),
      ),
      body: Stack(children: [
        const IgnorePointer(child: WebViewCanvas()),
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            // ── 开关卡片 ──
            _card(c, [
              Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [c.success, c.success.withValues(alpha: 0.7)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.chat_rounded, size: 22, color: Colors.white),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('启用桥接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text('让QQ/微信消息自动由 Solvhen AI 回复',
                    style: TextStyle(fontSize: 13, color: c.textTertiary)),
                ])),
                Switch(
                  value: _enabled,
                  onChanged: _toggle,
                  activeColor: c.success,
                ),
              ]),
            ]),

            const SizedBox(height: 12),

            // ── 端口卡片 ──
            _card(c, [
              const Text('WebSocket 端口', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(fontSize: 18, color: c.textPrimary, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: '13579',
                      hintStyle: TextStyle(color: c.textPlaceholder),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: c.separator),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _changePort,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('应用'),
                ),
              ]),
              const SizedBox(height: 6),
              Text('NapCatQQ 反向 WebSocket 地址：ws://手机IP:${_portCtrl.text}/onebot',
                style: TextStyle(fontSize: 11, color: c.textTertiary)),
            ]),

            const SizedBox(height: 12),

            // ── 状态卡片 ──
            _card(c, [
              Row(children: [
                Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _running ? c.success : c.textPlaceholder,
                  ),
                ),
                const SizedBox(width: 10),
                Text(_running ? '运行中' : '未启动',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                    color: _running ? c.success : c.textTertiary)),
                const Spacer(),
                if (_running)
                  Text('$_clients 个客户端连接',
                    style: TextStyle(fontSize: 13, color: c.textSecondary)),
              ]),
            ]),

            const SizedBox(height: 20),

            // ── 使用说明 ──
            _card(c, [
              const Text('📋 使用步骤', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              _step('1', '在电脑上安装 NapCatQQ', c),
              _step('2', 'NapCatQQ 设置 → 反向 WebSocket → 填入上面的地址', c),
              _step('3', '回到此页面打开"启用桥接"开关', c),
              _step('4', '用其他QQ给机器人QQ发消息 → Solvhen 自动回复', c),
              const SizedBox(height: 12),
              Text('提示：手机和电脑需在同一局域网内。',
                style: TextStyle(fontSize: 12, color: c.textTertiary)),
            ]),
          ],
        ),
      ]),
    );
  }

  Widget _card(ThemeColors c, List<Widget> children) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.glassBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.glassBorder, width: 0.5),
            boxShadow: c.shadowCard,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ),
    );
  }

  Widget _step(String num, String text, ThemeColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accent.withValues(alpha: 0.15),
          ),
          child: Center(child: Text(num, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.accent))),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.4))),
      ]),
    );
  }
}
