/// Solvhen — TTS语音设置页：多引擎切换 + 音色搜索 + 声音克隆 + 参数调节
///
/// 支持引擎：火山引擎（豆包）、Edge TTS、OpenAI TTS、GPT-SoVITS、自定义
/// - 火山引擎：国内最优，21+音色，支持声音克隆
/// - Edge TTS：免费，200+音色，国内可能被墙
/// - GPT-SoVITS：自部署声音克隆方案
/// - 通用滑块：语速(0.5-2.0)、音调(-0.5-0.5)、音量(0-1.0)
library;

import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../models/tts_provider.dart';
import '../services/database_service.dart';
import '../theme/theme_provider.dart';
import 'webview_canvas.dart';

/// TTS语音设置页
/// 功能：引擎选择(火山/Edge/系统/GPT-SoVITS/自定义)/音色选择/
///       速度/音调/音量调节/克隆声音管理
/// UI：竖排列表+玻璃态卡片+DropdownButton深色背景
class SettingsTtsPage extends ConsumerStatefulWidget {
  const SettingsTtsPage({super.key});
  @override
  ConsumerState<SettingsTtsPage> createState() => _SettingsTtsPageState();
}

/// TTS设置页状态——加载/保存语音配置
class _SettingsTtsPageState extends ConsumerState<SettingsTtsPage> with TickerProviderStateMixin {
  bool _loaded = false;                      // 加载完成标志
  TtsConfig _config = const TtsConfig();     // 当前TTS配置
  String _voiceSearch = '';                  // 音色搜索关键词
  late final AnimationController _entry;

  @override
  void initState() { super.initState(); _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 400)); _load(); }
  @override
  void dispose() { _entry.dispose(); super.dispose(); }

  /// 加载TTS配置
  ///
  /// 优先级：tts_config JSON > 旧版volcano_app_id/token降级
  /// 如果都没有则使用空TtsConfig（全部默认值）
  Future<void> _load() async {
    try {
      final cfg = await DB.getConfig();
      final r = cfg['tts_config'];
      if (r != null && r.isNotEmpty) {
        _config = TtsConfig.fromJson(jsonDecode(r) as Map<String, dynamic>);
      } else {
        // 旧配置降级：从独立config key迁移到tts_config JSON
        final appId = cfg['volcano_app_id'];
        if (appId != null && appId.isNotEmpty) {
          _config = TtsConfig(engineId: 'volcano', auth: {'volcano_app_id': appId, 'volcano_token': cfg['volcano_token'] ?? ''});
        }
      }
    } catch (_) {}
    setState(() => _loaded = true);
    _entry.forward();
  }

  /// 保存TTS配置 — 同时更新旧版config key以兼容老代码路径
  Future<void> _save() async {
    await DB.setConfig('tts_config', jsonEncode(_config.toJson()));
    // 火山引擎认证信息同步到旧config key — 兼容volcano_tts.dart直接读config
    if (_config.engineId == 'volcano') {
      await DB.setConfig('volcano_app_id', _config.auth['volcano_app_id'] ?? '');
      await DB.setConfig('volcano_token', _config.auth['volcano_token'] ?? '');
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 1)));
  }

  /// 当前选中的引擎定义
  TtsEngine? get _engine => findTtsEngine(_config.engineId);
  /// 过滤音色列表 — 按关键词搜索name和tags
  List<TtsVoice> get _filtered {
    final v = _engine?.voices ?? [];
    if (_voiceSearch.isEmpty) return v;
    final q = _voiceSearch.toLowerCase();
    return v.where((x) => x.name.toLowerCase().contains(q) || x.tags.any((t) => t.contains(q))).toList();
  }
  /// 更新认证字段（不可变更新模式）
  void _setAuth(String k, String v) { final a = Map<String,String>.from(_config.auth); a[k] = v; setState(() => _config = _config.copyWith(auth: a)); }

  /// 声音克隆 — 选择音频文件 + 命名
  ///
  /// 流程：FilePicker选文件 → AlertDialog命名 → 添加到clonedVoices列表
  /// ⚠️ 仅支持支持克隆的引擎（volcano/gpt-sovits）
  Future<void> _clone() async {
    if (!(_engine?.supportsCloning ?? false)) return;
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.audio);
      if (r == null || r.files.isEmpty) return;
      final path = r.files.first.path; if (path == null) return;
      final nc = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('命名克隆声音'),
          content: TextField(controller: nc, decoration: const InputDecoration(hintText: '我的声音'), autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, nc.text.trim().isEmpty ? '我的声音' : nc.text.trim()), child: const Text('确认')),
          ],
        ),
      );
      if (name == null) return;
      setState(() {
        final clones = List<ClonedVoice>.from(_config.clonedVoices);
        clones.add(ClonedVoice(id: 'clone_${DateTime.now().millisecondsSinceEpoch}', name: name, engineId: _config.engineId, audioPath: path));
        _config = _config.copyWith(clonedVoices: clones);
      });
    } catch (_) {}
  }

  void _rm(int i) { final c = List<ClonedVoice>.from(_config.clonedVoices)..removeAt(i); setState(() => _config = _config.copyWith(clonedVoices: c)); }

  // ── UI构建辅助方法 ──
  Widget _h(String t, ThemeColors c) => Text(t, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.textPrimary, letterSpacing: -0.3));
  Widget _glass(List<Widget> ch, ThemeColors c) => ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: c.glassBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.glassBorder, width: 0.5), boxShadow: c.shadowGlass), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: ch))));

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    if (!_loaded) return Container(decoration: BoxDecoration(gradient: c.bgGradient), child: const Center(child: CircularProgressIndicator(color: Color(0xFF5856D6))));
    final engine = _engine; final voices = _filtered;
    return FadeTransition(opacity: CurvedAnimation(parent: _entry, curve: Curves.easeOut), child: Scaffold(backgroundColor: c.bgRoot,
      appBar: AppBar(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, title: Text('TTS 语音', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary))),
      body: Stack(children: [const IgnorePointer(child: WebViewCanvas()), ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        _h('引擎', c), const SizedBox(height: 10),
        _glass([...allTtsEngines.map((e) => _engineTile(e, c))], c),
        const SizedBox(height: 28),
        // 认证字段 — 不同引擎有不同的auth配置（如火山需要appId+token）
        if (engine != null && engine.authFields.isNotEmpty) ...[
          _h('${engine.name} 认证', c), const SizedBox(height: 10),
          _glass([for (final f in engine.authFields) _field(f.label, _config.auth[f.key] ?? '', (v) => _setAuth(f.key, v), c)], c),
          const SizedBox(height: 28),
        ],
        _h('音色', c), const SizedBox(height: 10),
        // 音色搜索 — 超过6个音色时显示搜索框
        if (voices.length > 6) Padding(padding: const EdgeInsets.only(bottom: 12), child: _search(c)),
        _glass([if (voices.isEmpty) Text('该引擎无预置音色', style: TextStyle(fontSize: 13, color: c.textTertiary)) else ...voices.map((v) => _voiceTile(v, c))], c),
        const SizedBox(height: 28),
        _h('声音调节', c), const SizedBox(height: 10),
        // 三个滑块：语速/音调/音量 — 实时调节，变更即生效
        _glass([
          _slider('语速', _config.speed, 0.5, 2.0, (v) => setState(() => _config = _config.copyWith(speed: v)), c),
          const SizedBox(height: 6),
          _slider('音调', _config.pitch, -0.5, 0.5, (v) => setState(() => _config = _config.copyWith(pitch: v)), c),
          const SizedBox(height: 6),
          _slider('音量', _config.volume, 0.0, 1.0, (v) => setState(() => _config = _config.copyWith(volume: v)), c),
        ], c),
        // 声音克隆 — 仅支持克隆的引擎显示（火山/GPT-SoVITS）
        if (engine?.supportsCloning ?? false) ...[
          const SizedBox(height: 28), _h('声音克隆', c), const SizedBox(height: 10),
          _glass([
            Text('上传 10-30 秒清晰人声音频', style: TextStyle(fontSize: 12, color: c.textTertiary)),
            const SizedBox(height: 12),
            _outline('选择音频文件', Icons.upload_file_rounded, _clone, c),
            // 已克隆列表 — 可删除
            if (_config.clonedVoices.isNotEmpty) ...[
              const SizedBox(height: 14), const Divider(),
              ...List.generate(_config.clonedVoices.length, (i) {
                final cv = _config.clonedVoices[i];
                return ListTile(
                  title: Text(cv.name, style: TextStyle(fontSize: 14, color: c.textPrimary)),
                  subtitle: Text('${engine?.name ?? '?'} · ${cv.audioPath?.split('/').last ?? ''}', style: TextStyle(fontSize: 11, color: c.textTertiary)),
                  dense: true, contentPadding: EdgeInsets.zero,
                  trailing: IconButton(icon: Icon(Icons.delete_outline_rounded, size: 18, color: c.danger.withValues(alpha: 0.7)), onPressed: () => _rm(i)),
                );
              }),
            ],
          ], c),
        ],
        const SizedBox(height: 32),
        Align(alignment: Alignment.centerRight, child: _saveBtn(c)),
      ])])));
  }

  /// 引擎选择瓷砖 — 单选圆点 + 引擎名 + 克隆标签
  Widget _engineTile(TtsEngine e, ThemeColors c) => GestureDetector(
    onTap: () => setState(() => _config = _config.copyWith(engineId: e.id, voiceId: findTtsEngine(e.id)?.voices.firstOrNull?.id ?? '')),
    child: AnimatedContainer(duration: const Duration(milliseconds: 250), margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: _config.engineId == e.id ? c.accent.withValues(alpha: 0.08) : Colors.transparent, borderRadius: BorderRadius.circular(14), border: _config.engineId == e.id ? Border.all(color: c.accent.withValues(alpha: 0.25)) : null),
      child: Row(children: [
        AnimatedContainer(duration: const Duration(milliseconds: 250), width: 18, height: 18, margin: const EdgeInsets.only(right: 12), decoration: BoxDecoration(shape: BoxShape.circle, color: _config.engineId == e.id ? c.accent : Colors.transparent, border: Border.all(color: _config.engineId == e.id ? c.accent : c.textPlaceholder, width: 2))),
        Expanded(child: Text(e.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.textPrimary))),
        if (e.supportsCloning) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)), child: Text('克隆', style: TextStyle(fontSize: 11, color: c.accent, fontWeight: FontWeight.w500))),
      ])));

  /// 音色选择瓷砖 — 单选圆点 + 音色名 + 性别图标 + 标签
  Widget _voiceTile(TtsVoice v, ThemeColors c) => GestureDetector(
    onTap: () => setState(() => _config = _config.copyWith(voiceId: v.id)),
    child: Container(margin: const EdgeInsets.only(bottom: 2), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: _config.voiceId == v.id ? c.accent.withValues(alpha: 0.06) : Colors.transparent, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        AnimatedContainer(duration: const Duration(milliseconds: 250), width: 16, height: 16, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(shape: BoxShape.circle, color: _config.voiceId == v.id ? c.accent : Colors.transparent, border: Border.all(color: _config.voiceId == v.id ? c.accent : c.textPlaceholder, width: 2))),
        Text(v.name, style: TextStyle(fontSize: 14, color: c.textPrimary)), const SizedBox(width: 6),
        Icon(v.gender == 'male' ? Icons.male : Icons.female, size: 14, color: v.gender == 'male' ? Colors.blue : const Color(0xFFFF2D55)),
        if (v.tags.isNotEmpty) const SizedBox(width: 8),
        ...v.tags.map((t) => Container(margin: const EdgeInsets.only(right: 4), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(6)), child: Text(t, style: TextStyle(fontSize: 10, color: c.accent)))),
      ])));

  /// 搜索框 — 玻璃态毛玻璃背景
  Widget _search(ThemeColors c) => ClipRRect(borderRadius: BorderRadius.circular(14), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: TextField(decoration: InputDecoration(hintText: '搜索音色...', hintStyle: TextStyle(color: c.textPlaceholder), prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.textTertiary), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none), filled: true, fillColor: c.glassBg), onChanged: (v) => setState(() => _voiceSearch = v), style: TextStyle(fontSize: 14, color: c.textPrimary))));

  /// 认证字段输入 — 标签 + TextField
  Widget _field(String l, String v, ValueChanged<String> cb, ThemeColors c) {
    final fill = c.bgCard.withValues(alpha: 0.5);
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [SizedBox(width: 55, child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary))), const SizedBox(width: 10), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4), child: TextField(controller: TextEditingController(text: v)..selection = TextSelection.collapsed(offset: v.length), style: TextStyle(fontSize: 14, color: c.textPrimary), decoration: InputDecoration(contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), filled: true, fillColor: fill), onChanged: cb))))]));
  }

  /// 滑块组件 — 标签 + 数值显示 + Slider
  Widget _slider(String l, double v, double min, double max, ValueChanged<double> cb, ThemeColors c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(l, style: TextStyle(fontSize: 13, color: c.textSecondary)),
      Text(v.toStringAsFixed(1), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent)),
    ]),
    SliderTheme(data: SliderThemeData(activeTrackColor: c.accent, inactiveTrackColor: c.accent.withValues(alpha: 0.10), thumbColor: c.accent, overlayColor: c.accent.withValues(alpha: 0.08), trackHeight: 4), child: Slider(value: v, min: min, max: max, onChanged: cb)),
  ]);

  Widget _outline(String t, IconData i, VoidCallback cb, ThemeColors c) => GestureDetector(onTap: cb, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.accent.withValues(alpha: 0.15))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 16, color: c.accent), const SizedBox(width: 8), Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent))])));
  Widget _saveBtn(ThemeColors c) => GestureDetector(onTap: _save, child: Container(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12), decoration: BoxDecoration(gradient: c.accentGradient, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]), child: const Text('保存', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))));
}
