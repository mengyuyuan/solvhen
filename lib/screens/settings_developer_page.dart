import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security/developer_mode.dart';
import '../services/database_service.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';

class SettingsDeveloperPage extends ConsumerStatefulWidget {
  const SettingsDeveloperPage({super.key});

  @override
  ConsumerState<SettingsDeveloperPage> createState() =>
      _SettingsDeveloperPageState();
}

class _SettingsDeveloperPageState extends ConsumerState<SettingsDeveloperPage> {
  final _urlController = TextEditingController();
  final _scrollController = ScrollController();
  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;
  bool _showToken = false;
  String _token = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await DB.getConfig();
    final token = await DeveloperCredentials().readToken() ?? '';
    if (!mounted) return;
    setState(() {
      _enabled = config['developer_mode'] == 'true';
      _urlController.text = config['dev_server_url'] ?? '';
      _token = token;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  Future<bool> _confirmEnable() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('开启开发者重建通道？'),
            content: const Text(
              '开启后，模型可以看到 rebuild_self，但每次仍会二次确认。该通道能编译并替换当前应用，只应连接你控制的开发机；不要向任何人泄露配对 token。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保持关闭'),
              ),
              FilledButton.tonal(
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
    if (value) {
      final normalized = normalizePrivateDeveloperUrl(_urlController.text);
      if (normalized == null) {
        _message('先填写有效的回环或私网开发服务器地址', error: true);
        return;
      }
      if (!await _confirmEnable()) return;
      setState(() => _busy = true);
      try {
        final token = await DeveloperCredentials().loadOrCreateToken();
        await DB.setConfig('dev_server_url', normalized.toString());
        await DB.setConfig('developer_mode', 'true');
        DeveloperModeSession.instance.setEnabled(true);
        if (!mounted) return;
        setState(() {
          _enabled = true;
          _token = token;
          _urlController.text = normalized.toString();
        });
        _message('开发者模式仅对本机配置生效；每次重建仍需确认');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    await DB.setConfig('developer_mode', 'false');
    DeveloperModeSession.instance.setEnabled(false);
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _showToken = false;
    });
    _message('开发者模式已关闭，rebuild_self 已从模型工具列表隐藏');
  }

  Future<void> _saveAddress() async {
    if (_busy) return;
    final normalized = normalizePrivateDeveloperUrl(_urlController.text);
    if (normalized == null) {
      _message('地址只允许 http(s)://localhost、回环地址或私网 IP', error: true);
      return;
    }
    await DB.setConfig('dev_server_url', normalized.toString());
    if (!mounted) return;
    setState(() => _urlController.text = normalized.toString());
    _message('开发服务器地址已保存');
  }

  Future<void> _copyToken() async {
    var token = _token;
    if (token.isEmpty) {
      token = await DeveloperCredentials().loadOrCreateToken();
      if (mounted) setState(() => _token = token);
    }
    await Clipboard.setData(ClipboardData(text: token));
    _message('配对 token 已复制；请仅填入你控制的开发服务器');
  }

  Future<void> _rotateToken() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('轮换开发服务器 token？'),
        content: const Text(
            '旧 token 会立即失效。开发机必须同步更新 SOLVHEN_REBUILD_TOKEN 后才能再次重建。'),
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
      final token = await DeveloperCredentials().rotateToken();
      if (!mounted) return;
      setState(() {
        _token = token;
        _showToken = false;
      });
      _message('token 已轮换，旧 token 已失效');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message, {bool error = false}) {
    if (!mounted) return;
    final colors = ThemeColors(ref.read(themeProvider));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? colors.danger : null,
      ),
    );
  }

  String get _maskedToken {
    if (_token.isEmpty) return '尚未生成';
    if (_showToken) return _token;
    return '${_token.substring(0, 6)} •••••••••••••••• ${_token.substring(_token.length - 4)}';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(title: const Text('开发者模式')),
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
                _statusPanel(colors),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '私网端点'),
                SolvhenPanel(
                  colors: colors,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _urlController,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '开发服务器 URL',
                          hintText: 'http://192.168.1.10:9120',
                          prefixIcon: Icon(Icons.lan_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _saveAddress,
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('验证并保存地址'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '拒绝公网域名、URL 内账号、query 和 fragment。HTTP 只用于受信任的同一局域网；服务器还会校验来源 IP。',
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '256 位配对凭证'),
                _tokenPanel(colors),
                const SizedBox(height: 20),
                SolvhenSectionLabel(colors: colors, label: '服务端约束'),
                SolvhenPanel(
                  colors: colors,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _rule(colors, Icons.key_rounded, 'Bearer token',
                          '仅存 Android Keystore，服务器用常量时间比较'),
                      _rule(colors, Icons.fingerprint_rounded, '一次性 nonce',
                          '每个请求唯一，重放请求会被拒绝'),
                      _rule(colors, Icons.router_outlined, '客户端白名单',
                          '仅回环/私网来源，可进一步指定允许 IP'),
                      _rule(colors, Icons.touch_app_outlined, '逐次确认',
                          '信任模式也不会跳过 rebuild_self 确认'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _statusPanel(ThemeColors colors) {
    final statusColor = _enabled ? colors.warning : colors.success;
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
              border: Border.all(color: statusColor.withValues(alpha: 0.24)),
            ),
            child: Icon(Icons.terminal_rounded, color: statusColor),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _enabled ? '开发者通道已开启' : '开发者通道已锁定',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _enabled ? 'rebuild_self 可见，但始终逐次确认' : '普通模型工具集中不暴露自重建能力',
                  style: TextStyle(color: colors.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(value: _enabled, onChanged: _busy ? null : _toggle),
        ],
      ),
    );
  }

  Widget _tokenPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _maskedToken,
                    style: TextStyle(
                      color: colors.navy,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _showToken ? '隐藏' : '显示',
                  onPressed: _token.isEmpty
                      ? null
                      : () => setState(() => _showToken = !_showToken),
                  icon: Icon(_showToken
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _copyToken,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('复制 token'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _rotateToken,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('立即轮换'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '开发机启动服务时，把同一 token 写入 SOLVHEN_REBUILD_TOKEN。token 不写入 SQLite、日志或诊断包。',
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ),
      );

  Widget _rule(
    ThemeColors colors,
    IconData icon,
    String title,
    String detail,
  ) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: colors.accent),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
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
