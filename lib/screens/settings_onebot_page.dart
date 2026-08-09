import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security/onebot_credentials.dart';
import '../services/database_service.dart';
import '../services/onebot_bridge.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';

class SettingsOneBotPage extends ConsumerStatefulWidget {
  const SettingsOneBotPage({super.key});

  @override
  ConsumerState<SettingsOneBotPage> createState() => _SettingsOneBotPageState();
}

class _SettingsOneBotPageState extends ConsumerState<SettingsOneBotPage> {
  final _portCtrl = TextEditingController(text: '13579');
  bool _enabled = false;
  bool _running = false;
  bool _loading = true;
  bool _busy = false;
  bool _allowInsecureLan = false;
  bool _showToken = false;
  int _clients = 0;
  String _accessToken = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    OneBotBridge().onStatusChange = (running, clients) {
      if (!mounted) return;
      setState(() {
        _running = running;
        _clients = clients;
      });
    };
  }

  Future<void> _loadConfig() async {
    final cfg = await DB.getConfig();
    final bridge = OneBotBridge();
    final token = await OneBotCredentials().loadOrCreateToken();
    if (!mounted) return;
    setState(() {
      _enabled = cfg['onebot_enabled'] == 'true';
      _portCtrl.text = cfg['onebot_port'] ?? '13579';
      _allowInsecureLan = cfg['onebot_allow_insecure_lan'] == 'true';
      _accessToken = token;
      _running = bridge.isRunning;
      _clients = bridge.clientCount;
      _loading = false;
    });
  }

  int _port() => (int.tryParse(_portCtrl.text) ?? 13579).clamp(1024, 65535);

  Future<bool> _confirmInsecureLan() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('允许明文局域网 WebSocket？'),
            content: const Text(
              '当前版本尚未配置 WSS 证书。只应在你信任的同一局域网使用；连接必须携带 256 位 Bearer token，且仍受 IP、连接数、消息大小和速率限制。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保持关闭'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('我了解风险'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    if (value && !_allowInsecureLan) {
      if (!await _confirmInsecureLan()) return;
      await DB.setConfig('onebot_allow_insecure_lan', 'true');
      if (!mounted) return;
      setState(() => _allowInsecureLan = true);
    }
    setState(() => _busy = true);
    try {
      if (value) {
        final port = _port();
        _portCtrl.text = port.toString();
        await DB.setConfig('onebot_port', '$port');
        final started = await OneBotBridge().start(
          port: port,
          accessToken: _accessToken,
          allowInsecureLan: _allowInsecureLan,
        );
        await DB.setConfig('onebot_enabled', '$started');
        if (!mounted) return;
        setState(() {
          _enabled = started;
          _running = started && OneBotBridge().isRunning;
        });
        if (!started) _showMessage('桥接启动失败，请检查端口是否被占用', error: true);
      } else {
        await OneBotBridge().stop();
        await DB.setConfig('onebot_enabled', 'false');
        if (!mounted) return;
        setState(() {
          _enabled = false;
          _running = false;
          _clients = 0;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAllowInsecureLan(bool value) async {
    if (_busy) return;
    if (value && !await _confirmInsecureLan()) return;
    if (!value && _enabled) await OneBotBridge().stop();
    await DB.setConfig('onebot_allow_insecure_lan', '$value');
    if (!value) await DB.setConfig('onebot_enabled', 'false');
    if (!mounted) return;
    setState(() {
      _allowInsecureLan = value;
      if (!value) {
        _enabled = false;
        _running = false;
        _clients = 0;
      }
    });
  }

  Future<void> _changePort() async {
    if (_busy) return;
    final port = _port();
    _portCtrl.text = '$port';
    setState(() => _busy = true);
    try {
      await DB.setConfig('onebot_port', '$port');
      if (_enabled) {
        final started = await OneBotBridge().restart(
          port: port,
          accessToken: _accessToken,
          allowInsecureLan: _allowInsecureLan,
        );
        await DB.setConfig('onebot_enabled', '$started');
        if (mounted) {
          setState(() {
            _enabled = started;
            _running = started;
          });
        }
      }
      _showMessage('端口已应用');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyToken() async {
    if (_accessToken.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _accessToken));
    _showMessage('Bearer token 已复制，请勿发送给不可信的人');
  }

  Future<void> _rotateToken() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('轮换 OneBot token？'),
        content: const Text('所有现有客户端会立即断开，旧 token 永久失效。你需要在客户端重新填写新 token。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认轮换'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await OneBotBridge().stop();
      final token = await OneBotCredentials().rotateToken();
      var started = false;
      if (_enabled) {
        started = await OneBotBridge().start(
          port: _port(),
          accessToken: token,
          allowInsecureLan: _allowInsecureLan,
        );
      }
      await DB.setConfig('onebot_enabled', '$started');
      if (!mounted) return;
      setState(() {
        _accessToken = token;
        _showToken = false;
        _enabled = started;
        _running = started;
        _clients = 0;
      });
      _showMessage('token 已轮换，旧 token 已失效');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            error ? ThemeColors(ref.read(themeProvider)).danger : null,
      ),
    );
  }

  @override
  void dispose() {
    OneBotBridge().onStatusChange = null;
    _portCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(
        title: const Text('QQ/微信 桥接'),
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
                _statusPanel(colors),
                const SizedBox(height: 20),
                _section(colors, '连接许可', 'LAN ONLY'),
                _permissionPanel(colors),
                const SizedBox(height: 18),
                _section(colors, '访问凭证', '256-BIT TOKEN'),
                _tokenPanel(colors),
                const SizedBox(height: 18),
                _section(colors, '客户端配置', 'REVERSE WS'),
                _connectionPanel(colors),
                const SizedBox(height: 18),
                _limitsPanel(colors),
                const SizedBox(height: 18),
                _guidePanel(colors),
              ],
            ),
        ],
      ),
    );
  }

  Widget _statusPanel(ThemeColors colors) {
    final tone = _running ? colors.success : colors.navy;
    return SolvhenPanel(
      colors: colors,
      borderColor: tone.withValues(alpha: 0.28),
      padding: const EdgeInsets.all(17),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.hub_outlined, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _running ? '局域网桥接运行中' : '桥接默认关闭',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _running ? '$_clients / 2 个客户端已连接' : '不会监听任何网络端口',
                  style: TextStyle(color: colors.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          if (_busy)
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: tone),
            )
          else
            Switch(
              value: _enabled,
              onChanged: _toggle,
              activeThumbColor: colors.success,
            ),
        ],
      ),
    );
  }

  Widget _permissionPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(15),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowInsecureLan,
          onChanged: _busy ? null : _setAllowInsecureLan,
          activeThumbColor: colors.warning,
          secondary: Icon(Icons.lan_outlined, color: colors.warning),
          title: Text(
            '允许明文局域网 WS',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            'WSS 不可用时才开启；关闭会立即停止桥接。',
            style: TextStyle(color: colors.textTertiary, fontSize: 11),
          ),
        ),
      );

  Widget _tokenPanel(ThemeColors colors) {
    final masked = _accessToken.length >= 10
        ? '${_accessToken.substring(0, 6)}••••${_accessToken.substring(_accessToken.length - 4)}'
        : '尚未生成';
    return SolvhenPanel(
      colors: colors,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.key_rounded, size: 19, color: colors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: SelectableText(
                  _showToken ? _accessToken : masked,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: _showToken ? 11 : 13,
                    height: 1.45,
                  ),
                ),
              ),
              IconButton(
                tooltip: _showToken ? '隐藏 token' : '显示 token',
                onPressed: () => setState(() => _showToken = !_showToken),
                icon: Icon(
                  _showToken
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: colors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyToken,
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('复制'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _rotateToken,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('轮换'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectionPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portCtrl,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'WebSocket 端口',
                      hintText: '13579',
                      helperText: '允许范围 1024–65535',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _busy ? null : _changePort,
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: colors.accentFaint,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.separator),
              ),
              child: Text(
                _allowInsecureLan
                    ? 'ws://手机局域网IP:${_port()}/onebot\nAuthorization: Bearer <复制的 token>'
                    : '连接地址已锁定：先单独允许明文局域网 WS',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  height: 1.55,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _limitsPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        showShadow: false,
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SolvhenTag(colors: colors, label: 'LAN IP ONLY'),
            SolvhenTag(colors: colors, label: 'BEARER TOKEN'),
            SolvhenTag(colors: colors, label: 'MAX 2 CLIENTS'),
            SolvhenTag(colors: colors, label: '64 KB / FRAME'),
            SolvhenTag(colors: colors, label: '20 MSG / MIN'),
          ],
        ),
      );

  Widget _guidePanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '客户端接入',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 11),
            _step(colors, '01', '在同一可信局域网配置 NapCatQQ 反向 WebSocket。'),
            _step(colors, '02',
                '使用上方地址，并把复制的 token 放入 Authorization Bearer header。'),
            _step(colors, '03', '先允许明文局域网 WS，再打开桥接；不用时立即关闭。'),
          ],
        ),
      );

  Widget _step(ThemeColors colors, String number, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              number,
              style: TextStyle(
                color: colors.accent,
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );

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
}
