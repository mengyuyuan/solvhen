/// Solvhen — 安全 OTA 更新设置
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart' as dbs;
import '../services/update_service.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';

class SettingsUpdatePage extends ConsumerStatefulWidget {
  const SettingsUpdatePage({super.key});

  @override
  ConsumerState<SettingsUpdatePage> createState() => _SettingsUpdatePageState();
}

class _SettingsUpdatePageState extends ConsumerState<SettingsUpdatePage> {
  final _urlCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _checking = false;
  bool _downloading = false;
  bool _checked = false;
  double _progress = 0;
  String? _notice;
  bool _noticeIsError = false;
  UpdateInfo? _update;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await dbs.DB.getConfig();
    final stored = cfg['update_url']?.trim() ?? '';
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = stored;
      _loading = false;
      if (stored.isNotEmpty && normalizeOfficialUpdateBaseUrl(stored) == null) {
        _notice = '旧版非官方地址已停止自动访问，请改用官方 HTTPS 地址。';
        _noticeIsError = true;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final raw = _urlCtrl.text.trim();
    final normalized = normalizeOfficialUpdateBaseUrl(raw);
    if (raw.isNotEmpty && normalized == null) {
      _setNotice('只允许 https://$officialUpdateHost，其他地址不会保存。', true);
      return;
    }
    setState(() => _saving = true);
    try {
      await dbs.DB.setConfig('update_url', normalized ?? '');
      if (!mounted) return;
      setState(() {
        _urlCtrl.text = normalized ?? '';
        _update = null;
        _checked = false;
      });
      _setNotice(
        normalized == null ? '自动更新检查已关闭。' : '官方更新地址已保存。',
        false,
      );
    } catch (error) {
      _setNotice('保存失败：$error', true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    final normalized = normalizeOfficialUpdateBaseUrl(_urlCtrl.text);
    if (normalized == null) {
      _setNotice('请先填写并保存官方 HTTPS 更新地址。', true);
      return;
    }
    if (!hasOfficialUpdatePublicKey) {
      _setNotice('当前构建未内置 OTA Ed25519 发布公钥，更新功能保持锁定。', true);
      return;
    }
    setState(() {
      _checking = true;
      _checked = false;
      _update = null;
      _notice = null;
    });
    try {
      final pkg = await dbs.DB.getConfig();
      final currentCode = int.tryParse(pkg['version_code'] ?? '5') ?? 5;
      final update = await checkForUpdate(
        updateUrl: normalized,
        currentVersionCode: currentCode,
      );
      if (!mounted) return;
      setState(() {
        _update = update;
        _checked = true;
      });
      if (update == null) _setNotice('未发现可用的新版本。', false);
    } catch (error) {
      _setNotice('检查失败：$error', true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final update = _update;
    if (update == null || _downloading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('安装 Solvhen ${update.version}？'),
        content: const Text(
          '应用会复验 Ed25519 清单签名、官方域名、包名、APK SHA-256 和签名证书，然后交给 Android 系统安装器。系统仍会再次要求你确认安装。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载并校验'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _downloading = true;
      _progress = 0;
      _notice = null;
    });
    try {
      final path = await downloadUpdate(
        update,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final opened = await installApk(path, update);
      _setNotice(
        opened ? '校验通过，已打开 Android 系统安装器。' : '无法打开系统安装器。',
        !opened,
      );
    } catch (error) {
      _setNotice('更新已阻止：$error', true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _setNotice(String value, bool error) {
    if (!mounted) return;
    setState(() {
      _notice = value;
      _noticeIsError = error;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    final configured = normalizeOfficialUpdateBaseUrl(_urlCtrl.text) != null;
    final ready = configured && hasOfficialUpdatePublicKey;
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(
        title: const Text('检查更新'),
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
                _statusPanel(colors, configured, ready),
                const SizedBox(height: 20),
                SolvhenSectionLabel(
                  colors: colors,
                  label: '官方更新通道',
                  trailing: Text(
                    'HTTPS ONLY',
                    style: TextStyle(
                      color: colors.textPlaceholder,
                      fontFamily: 'monospace',
                      fontSize: 9,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                _endpointPanel(colors),
                const SizedBox(height: 16),
                _securityPanel(colors),
                if (_notice != null) ...[
                  const SizedBox(height: 14),
                  _noticePanel(colors),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed:
                        _checking || _downloading ? null : _checkForUpdates,
                    icon: _checking
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.radar_rounded, size: 19),
                    label: Text(_checking ? '正在验证更新清单' : '检查官方更新'),
                  ),
                ),
                if (_update != null) ...[
                  const SizedBox(height: 18),
                  _updatePanel(colors, _update!),
                ] else if (_checked) ...[
                  const SizedBox(height: 18),
                  _emptyResult(colors),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _statusPanel(ThemeColors colors, bool configured, bool ready) {
    final tone = ready
        ? colors.success
        : configured
            ? colors.warning
            : colors.navy;
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
            child: Icon(
              ready
                  ? Icons.verified_user_outlined
                  : configured
                      ? Icons.lock_outline_rounded
                      : Icons.cloud_off_outlined,
              color: tone,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready
                      ? '官方安全通道已就绪'
                      : configured
                          ? '更新通道已锁定'
                          : '默认不联网检查',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  ready
                      ? '域名、清单与 APK 身份均需验证'
                      : configured
                          ? 'release 构建需要注入 Ed25519 发布公钥'
                          : '填写并保存官方地址后才会启用',
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          SolvhenTag(
            colors: colors,
            label: ready
                ? 'READY'
                : configured
                    ? 'LOCKED'
                    : 'OFFLINE',
            color: tone,
          ),
        ],
      ),
    );
  }

  Widget _endpointPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {
                _update = null;
                _checked = false;
              }),
              decoration: InputDecoration(
                labelText: 'OTA 更新地址',
                hintText: officialUpdateBaseUrl,
                helperText: '留空即关闭；不会访问任意第三方或临时隧道',
                prefixIcon: Icon(Icons.link_rounded, color: colors.accent),
              ),
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => setState(
                              () => _urlCtrl.text = officialUpdateBaseUrl,
                            ),
                    child: const Text('填入官方地址'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _securityPanel(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
        showShadow: false,
        child: Column(
          children: [
            _checkRow(colors, '固定官方 HTTPS 域名', '$officialUpdateHost only'),
            Divider(height: 18, color: colors.separator),
            _checkRow(
              colors,
              '更新清单签名',
              'ED25519 REQUIRED',
              ok: hasOfficialUpdatePublicKey,
            ),
            Divider(height: 18, color: colors.separator),
            _checkRow(colors, '安装包身份', solvhenPackageName),
            Divider(height: 18, color: colors.separator),
            _checkRow(colors, '文件完整性', 'SHA-256 REQUIRED'),
            Divider(height: 18, color: colors.separator),
            _checkRow(colors, '签名证书', 'MATCH INSTALLED APP'),
            Divider(height: 18, color: colors.separator),
            _checkRow(colors, '安装授权', 'ALWAYS CONFIRM'),
          ],
        ),
      );

  Widget _checkRow(
    ThemeColors colors,
    String title,
    String value, {
    bool ok = true,
  }) =>
      Row(
        children: [
          Icon(
            ok
                ? Icons.check_circle_outline_rounded
                : Icons.lock_outline_rounded,
            size: 17,
            color: ok ? colors.success : colors.warning,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(title,
                style: TextStyle(color: colors.textSecondary, fontSize: 12)),
          ),
          Text(
            value,
            style: TextStyle(
              color: colors.textTertiary,
              fontFamily: 'monospace',
              fontSize: 9,
            ),
          ),
        ],
      );

  Widget _noticePanel(ThemeColors colors) {
    final tone = _noticeIsError ? colors.danger : colors.success;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(
            _noticeIsError
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline_rounded,
            color: tone,
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              _notice!,
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
  }

  Widget _updatePanel(ThemeColors colors, UpdateInfo update) => SolvhenPanel(
        colors: colors,
        borderColor: colors.accent.withValues(alpha: 0.32),
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '发现 ${update.version}',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SolvhenTag(colors: colors, label: 'VERIFIED MANIFEST'),
              ],
            ),
            if (update.changelog?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 10),
              Text(
                update.changelog!,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 15),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _progress,
                color: colors.accent,
                backgroundColor: colors.separator,
              ),
              const SizedBox(height: 7),
              Text(
                '下载并校验中 ${(_progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: colors.textTertiary,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _downloadAndInstall,
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: const Text('下载、校验并安装'),
                ),
              ),
          ],
        ),
      );

  Widget _emptyResult(ThemeColors colors) => SolvhenPanel(
        colors: colors,
        showShadow: false,
        child: Row(
          children: [
            Icon(Icons.task_alt_rounded, color: colors.success),
            const SizedBox(width: 10),
            Text(
              '当前版本已是最新',
              style: TextStyle(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
