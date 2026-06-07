/// Solvhen — 图片生成设置页：多模型槽位管理 + 玻璃态UI
///
/// 支持：147ai（gpt-image-2-client）、DALL-E、ComfyUI、自定义API
/// 可添加/删除多个图片生成模型槽位，每个独立配置厂商/模型/API地址/Key
library;
import 'dart:convert'; import 'dart:ui';
import 'package:flutter/material.dart'; import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/media_provider.dart'; import '../services/database_service.dart'; import '../theme/theme_provider.dart';
import 'webview_canvas.dart';

/// 图片生成设置页——图片模型供应商+槽位配置
class SettingsImagePage extends ConsumerStatefulWidget { const SettingsImagePage({super.key}); @override ConsumerState<SettingsImagePage> createState() => _State(); }
class _State extends ConsumerState<SettingsImagePage> with TickerProviderStateMixin {
  bool _loaded = false; List<MediaSlot> _slots = []; late final AnimationController _entry;
  @override void initState() { super.initState(); _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 400)); _load(); }
  @override void dispose() { _entry.dispose(); super.dispose(); }

  /// 从DB加载图片槽位配置 → image_slots JSON
  Future<void> _load() async {
    try {
      final cfg = await DB.getConfig();
      final r = cfg['image_slots'];
      if (r != null && r.isNotEmpty) _slots = imageSlotsFromJson(jsonDecode(r) as List?);
    } catch (_) {}
    setState(() => _loaded = true);
    _entry.forward();
  }

  /// 保存图片槽位到DB
  Future<void> _save() async {
    await DB.setConfig('image_slots', jsonEncode(slotsToJson(_slots)));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 1)));
  }

  /// 添加新槽位 — 默认147ai的gpt-image-2-client
  void _add() => setState(() => _slots.add(MediaSlot(slotId: 'img_${DateTime.now().millisecondsSinceEpoch}', vendorId: '147ai', modelId: 'gpt-image-2-client')));
  void _rm(int i) => setState(() => _slots.removeAt(i));

  Widget _h(String t, ThemeColors c) => Text(t, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.textPrimary, letterSpacing: -0.3));
  /// 玻璃态容器 — 统一毛玻璃卡片样式
  Widget _glass(List<Widget> ch, ThemeColors c) => ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: c.glassBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.glassBorder, width: 0.5), boxShadow: c.shadowGlass), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: ch))));

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    if (!_loaded) return Container(decoration: BoxDecoration(gradient: c.bgGradient), child: const Center(child: CircularProgressIndicator(color: Color(0xFF5856D6))));
    return FadeTransition(opacity: CurvedAnimation(parent: _entry, curve: Curves.easeOut), child: Scaffold(backgroundColor: c.bgRoot,
      appBar: AppBar(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, title: Text('图片生成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary))),
      body: Stack(children: [const IgnorePointer(child: WebViewCanvas()), ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        _h('图片生成', c), Padding(padding: const EdgeInsets.only(top: 4, bottom: 16), child: Text('147ai / DALL-E / ComfyUI / 自定义', style: TextStyle(fontSize: 12, color: c.textTertiary))),
        ...List.generate(_slots.length, (i) => _slot(i, c)),
        const SizedBox(height: 14), _outline('添加图片模型', Icons.add_rounded, _add, c),
        const SizedBox(height: 28),
        Align(alignment: Alignment.centerRight, child: _saveBtn(c)),
      ])])));
    }

  /// 单个图片模型槽位卡片
  Widget _slot(int i, ThemeColors c) {
    final s = _slots[i]; final vendor = findImageVendor(s.vendorId); final models = vendor?.models ?? []; final isCustom = s.vendorId == 'custom'; final fill = c.bgCard.withValues(alpha: 0.5);
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: _glass([
      Row(children: [Container(width: 32, height: 32, decoration: BoxDecoration(gradient: LinearGradient(colors: [c.accent, c.accent.withValues(alpha: 0.6)]), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.image_rounded, size: 16, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Text('模型 ${i+1}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textPrimary))), GestureDetector(onTap: () => _rm(i), child: Icon(Icons.close_rounded, size: 20, color: c.danger.withValues(alpha: 0.7)))]),
      const SizedBox(height: 14),
      // 厂商下拉 → 切换时自动选择该厂商的第一个模型
      _dd('厂商', s.vendorId, allImageVendors.map((v) => DropdownMenuItem(value: v.id, child: Text(v.name))).toList(), (v) => setState(() => _slots[i] = s.copyWith(vendorId: v!, modelId: findImageVendor(v)?.models.firstOrNull?.id ?? '')), c),
      if (models.isNotEmpty) ...[const SizedBox(height: 12), _dd('模型', s.modelId, models.map((m) => DropdownMenuItem(value: m.id, child: Text(m.name))).toList(), (v) => setState(() => _slots[i] = s.copyWith(modelId: v!)), c)],
      if (isCustom) ...[const SizedBox(height: 12), _tf('模型ID', s.modelId, (v) => setState(() => _slots[i] = s.copyWith(modelId: v)), c, fill)],
      const SizedBox(height: 12), _tf('API 地址', s.customUrl ?? (vendor?.defaultUrl ?? ''), (v) => setState(() => _slots[i] = s.copyWith(customUrl: v)), c, fill),
      const SizedBox(height: 12), _tf('API Key', s.apiKey ?? '', (v) => setState(() => _slots[i] = s.copyWith(apiKey: v)), c, fill),
    ], c));
  }

  /// ⚠️ 修复：下拉菜单使用主题色而非硬编码颜色 — 之前使用Color(0xFF8E8E93)等硬编码值破坏主题一致性
  Widget _dd(String l, String v, List<DropdownMenuItem<String>> items, ValueChanged<String?> cb, ThemeColors c) {
    final fill = c.bgCard.withValues(alpha: 0.5);
    return Row(children: [
      SizedBox(width: 52, child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary))),
      const SizedBox(width: 10),
      Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.glassBorder)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: v, isExpanded: true, items: items, onChanged: cb, style: TextStyle(fontSize: 14, color: c.textPrimary), dropdownColor: c.bgCard, borderRadius: BorderRadius.circular(12)))
      )))
    ]);
  }

  Widget _tf(String l, String v, ValueChanged<String> cb, ThemeColors c, Color fill) {
    return Row(children: [SizedBox(width: 52, child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary))), const SizedBox(width: 10), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: TextField(controller: TextEditingController(text: v)..selection = TextSelection.collapsed(offset: v.length), style: TextStyle(fontSize: 14, color: c.textPrimary), decoration: InputDecoration(contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), filled: true, fillColor: fill), onChanged: cb)))]);
  }
  Widget _outline(String t, IconData i, VoidCallback cb, ThemeColors c) => GestureDetector(onTap: cb, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16), border: Border.all(color: c.accent.withValues(alpha: 0.15))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 16, color: c.accent), const SizedBox(width: 8), Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent))])));
  Widget _saveBtn(ThemeColors c) => GestureDetector(onTap: _save, child: Container(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12), decoration: BoxDecoration(gradient: c.accentGradient, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]), child: const Text('保存', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))));
}
