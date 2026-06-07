/// Solvhen — 更新设置页面
library;

import 'package:flutter/material.dart';
import '../services/update_service.dart';
import '../services/database_service.dart' as dbs;

class SettingsUpdatePage extends StatefulWidget {
  const SettingsUpdatePage({super.key});
  @override
  State<SettingsUpdatePage> createState() => _SettingsUpdatePageState();
}

class _SettingsUpdatePageState extends State<SettingsUpdatePage> {
  final _urlCtrl = TextEditingController();
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  UpdateInfo? _update;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await dbs.DB.getConfig();
    final url = cfg['update_url'] ?? 'https://ota.sywy.app';
    _urlCtrl.text = url;
    setState(() {});
  }

  Future<void> _saveUrl() async {
    await dbs.DB.setConfig('update_url', _urlCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('更新地址已保存')),
      );
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _update = null;
    });
    try {
      final url = _urlCtrl.text.trim();
      final pkg = await dbs.DB.getConfig();
      final currentCode = int.tryParse(pkg['version_code'] ?? '4') ?? 4;
      final update = await checkForUpdate(
        updateUrl: url,
        currentVersionCode: currentCode,
      );
      setState(() => _update = update);
    } finally {
      setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    if (_update == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      final path = await downloadUpdate(
        _update!,
        onProgress: (p) => setState(() => _progress = p),
      );
      await installApk(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    } finally {
      setState(() => _downloading = false);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('更新')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 更新地址
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'OTA 更新地址',
              hintText: 'https://ota.sywy.app',
              helperText: '检查版本时使用此地址，末尾不带斜杠',
            ),
            onChanged: (_) => _saveUrl(),
          ),
          const SizedBox(height: 16),

          // 检查更新
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _checking ? null : _checkForUpdates,
              icon: _checking
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: Text(_checking ? '检查中...' : '检查更新'),
            ),
          ),

          // 更新结果
          if (_update != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('发现新版本: ${_update!.version}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    if (_update!.changelog != null) ...[
                      const SizedBox(height: 8),
                      Text(_update!.changelog!, style: const TextStyle(fontSize: 13)),
                    ],
                    const SizedBox(height: 12),
                    if (_downloading) ...[
                      LinearProgressIndicator(value: _progress),
                      const SizedBox(height: 4),
                      Text('下载中 ${(_progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(fontSize: 12)),
                    ] else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _downloadAndInstall,
                          icon: const Icon(Icons.download),
                          label: const Text('下载并安装'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],

          if (_update == null && !_checking) ...[
            const SizedBox(height: 16),
            const Center(
              child: Text('当前已是最新版本', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ],
      ),
    );
  }
}
