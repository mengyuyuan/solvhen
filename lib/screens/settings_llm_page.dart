/// Solvhen — LLM模型设置页：模型链拖拽排序 + 降级策略 + 玻璃态UI
///
/// 核心功能：
/// - 降级策略选择（顺序/并行/智能，失败按顺序降级）
/// - 模型链：支持添加/删除/拖拽重排多个LLM槽位
/// - 每个槽位独立配置厂商、模型、API地址、API Key
/// - 支持DeepSeek/OpenAI/豆包/Claude等11个厂商
/// - 保存时自动更新活跃模型的base_url/model/api_key到config表
library;

import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/llm_provider.dart';
import '../services/database_service.dart';
import '../theme/theme_provider.dart';
import 'webview_canvas.dart';

/// LLM模型链设置页
/// 功能：厂商选择/模型切换/槽位管理/策略(顺序降级or轮询负载)
/// UI：玻璃态卡片+DropdownButton深色背景+竖排列表+push导航
class SettingsLlmPage extends ConsumerStatefulWidget {
  const SettingsLlmPage({super.key});
  @override
  ConsumerState<SettingsLlmPage> createState() => _SettingsLlmPageState();
}

/// LLM设置页状态——加载/保存模型链配置
class _SettingsLlmPageState extends ConsumerState<SettingsLlmPage> with TickerProviderStateMixin {
  bool _loaded = false;                        // 数据加载完成标志
  LlmChainConfig _chain = const LlmChainConfig(); // 模型链配置
  String _primaryKey = '';                     // 主API Key（全局设置里的key，槽位key为空时回退）

  // ⚠️ 修复：之前使用_loaded控制加载状态，但动画控制器用_fadeCtrl — 统一使用_fadeCtrl控制入场动画
  late final AnimationController _fadeCtrl;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _load();
  }
  @override
  void dispose() { _fadeCtrl.dispose(); super.dispose(); }

  /// 从DB加载LLM链配置
  ///
  /// 加载逻辑：
  /// 1. 读取全局api_key作为主Key（槽位Key为空时的fallback）
  /// 2. 读取llm_chain JSON → LlmChainConfig反序列化
  /// 3. 如果链为空，从旧配置（llm_vendor + model）降级构建一个默认槽位
  Future<void> _load() async {
    try {
      final cfg = await DB.getConfig();
      _primaryKey = cfg['api_key'] ?? '';
      final raw = cfg['llm_chain'];
      if (raw != null && raw.isNotEmpty) _chain = LlmChainConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (_chain.slots.isEmpty) {
        // 旧配置降级：从llm_vendor/model构建单槽位链
        final vendor = cfg['llm_vendor'] ?? 'deepseek';
        final model = cfg['model'] ?? 'deepseek-v4-pro';
        _chain = LlmChainConfig(slots: [LlmSlot(slotId: _uid(), label: '主模型', vendorId: vendor, modelId: model)], activeSlotIndex: 0);
      }
    } catch (_) {
      // 解析失败 → 使用DeepSeek默认值兜底，确保页面不白屏
      _chain = LlmChainConfig(slots: [LlmSlot(slotId: _uid(), label: '主模型', vendorId: 'deepseek', modelId: 'deepseek-v4-pro')], activeSlotIndex: 0);
    }
    setState(() => _loaded = true);
    _fadeCtrl.forward();
  }

  /// 保存模型链配置到DB
  ///
  /// 同时更新全局config中的base_url/model/api_key，确保非链模式也能工作
  Future<void> _save() async {
    try {
      await DB.setConfig('llm_chain', jsonEncode(_chain.toJson()));
      final primary = _chain.activeSlot;
      if (primary != null) {
        await DB.setConfig('base_url', _resolveUrl(primary));
        await DB.setConfig('model', primary.modelId);
        final key = primary.apiKey ?? _primaryKey;
        if (key.isNotEmpty) await DB.setConfig('api_key', key);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('已保存'), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 1),
          backgroundColor: ThemeColors(ref.read(themeProvider)).accent.withValues(alpha: 0.9)),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), behavior: SnackBarBehavior.floating));
    }
  }

  /// 解析API地址：优先用槽位自定义URL → 厂商默认URL → DeepSeek兜底
  String _resolveUrl(LlmSlot s) => (s.customUrl != null && s.customUrl!.isNotEmpty) ? s.customUrl! : (findVendor(s.vendorId)?.defaultUrl ?? 'https://api.deepseek.com/v1');
  /// 生成唯一槽位ID — 时间戳+索引，避免碰撞
  String _uid() => '${DateTime.now().millisecondsSinceEpoch}_${_chain.slots.length}';

  void _addSlot() => setState(() => _chain = _chain.copyWith(slots: [..._chain.slots, LlmSlot(slotId: _uid(), label: '辅助模型 ${_chain.slots.length}', vendorId: 'deepseek', modelId: 'deepseek-v4-pro')]));
  /// 删除槽位 — 至少保留一个槽位，删除后自动重命名标签
  void _removeSlot(int i) {
    if (_chain.slots.length <= 1) return;
    setState(() {
      final s = List<LlmSlot>.from(_chain.slots)..removeAt(i);
      for (int j = 0; j < s.length; j++) s[j] = s[j].copyWith(label: j == 0 ? '主模型' : '辅助模型 $j');
      // 如果删除的是活跃槽位 → 回退到第一个
      _chain = _chain.copyWith(slots: s, activeSlotIndex: _chain.activeSlotIndex >= s.length ? 0 : _chain.activeSlotIndex);
    });
  }
  void _setActive(int i) => setState(() => _chain = _chain.copyWith(activeSlotIndex: i));

  /// 拖拽重排处理 — 维护活跃索引跟随移动
  ///
  /// [old] 原始位置, [nw] 新位置（ReorderableListView传入的newIndex已包含位移调整）
  void _onReorder(int old, int nw) {
    setState(() {
      final s = List<LlmSlot>.from(_chain.slots);
      // 向下移动时，index需要-1（因为先移除后插入，索引偏移）
      if (nw > old) nw--;
      final item = s.removeAt(old); s.insert(nw, item);
      for (int j = 0; j < s.length; j++) s[j] = s[j].copyWith(label: j == 0 ? '主模型' : '辅助模型 $j');
      // 调整activeSlotIndex跟踪被拖拽的元素
      int a = _chain.activeSlotIndex;
      if (old == a) a = nw;
      else if (old < a && nw >= a) a--;
      else if (old > a && nw <= a) a++;
      _chain = _chain.copyWith(slots: s, activeSlotIndex: a.clamp(0, s.length - 1));
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    if (!_loaded) return _loading(c);

    return FadeTransition(
      opacity: CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut),
      child: Scaffold(
          backgroundColor: c.bgRoot,
          appBar: AppBar(
            backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent,
            title: Text('LLM 模型', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary)),
          ),
          body: Stack(children: [const IgnorePointer(child: WebViewCanvas()), ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              _section('降级策略', c),
              const SizedBox(height: 10),
              _glassCard([...ChainStrategy.values.map((s) => _strategyTile(s, c))], c),
              const SizedBox(height: 28),
              _section('模型链', c),
              Padding(padding: const EdgeInsets.only(top: 4, bottom: 14), child: Text('拖拽排序 · 失败按顺序降级 · 点击切换活跃', style: TextStyle(fontSize: 12, color: c.textTertiary))),
              ReorderableListView.builder(
                // ⚠️ shrinkWrap+NeverScrollable → 嵌入外层ListView时必须，否则布局异常
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                itemCount: _chain.slots.length, onReorder: _onReorder, buildDefaultDragHandles: false,
                proxyDecorator: (child, _, __) => Material(color: Colors.transparent, elevation: 8, shadowColor: c.accent.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(18), child: child),
                itemBuilder: (_, i) => _buildSlotCard(i, c, key: ValueKey(_chain.slots[i].slotId)),
              ),
              const SizedBox(height: 16),
              _addButton(c),
              const SizedBox(height: 32),
              Align(alignment: Alignment.centerRight, child: _saveButton(c)),
            ],
          ),
        ]),
    ),
  );
  }

  Widget _loading(ThemeColors c) => Container(decoration: BoxDecoration(gradient: c.bgGradient), child: const Center(child: CircularProgressIndicator(color: Color(0xFF5856D6))));

  /// 章节标题 — 21px加粗，-0.3字间距（iOS风格）
  Widget _section(String t, ThemeColors c) => Text(t, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.textPrimary, letterSpacing: -0.3));

  /// 玻璃态容器 — 封装BackdropFilter + Container，统一设置页玻璃卡片样式
  Widget _glassCard(List<Widget> children, ThemeColors c) => ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: c.glassBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.glassBorder, width: 0.5), boxShadow: c.shadowGlass), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children))));

  /// 降级策略选项 — 单选圆形指示器 + 标签 + 描述
  Widget _strategyTile(ChainStrategy s, ThemeColors c) => GestureDetector(
    onTap: () => setState(() => _chain = _chain.copyWith(strategy: s)),
    child: AnimatedContainer(duration: const Duration(milliseconds: 250), margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: _chain.strategy == s ? c.accent.withValues(alpha: 0.08) : Colors.transparent, borderRadius: BorderRadius.circular(14), border: _chain.strategy == s ? Border.all(color: c.accent.withValues(alpha: 0.25)) : null),
      child: Row(children: [
        AnimatedContainer(duration: const Duration(milliseconds: 250), width: 18, height: 18, margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(shape: BoxShape.circle, color: _chain.strategy == s ? c.accent : Colors.transparent, border: Border.all(color: _chain.strategy == s ? c.accent : c.textPlaceholder, width: 2))),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textPrimary)),
          const SizedBox(height: 2), Text(s.desc, style: TextStyle(fontSize: 12, color: c.textTertiary)),
        ])),
      ])));

  /// 构建单个槽位卡片的包装器 — 传递所有必要参数给SlotGlassCard
  Widget _buildSlotCard(int index, ThemeColors c, {Key? key}) {
    final slot = _chain.slots[index]; final isActive = index == _chain.activeSlotIndex;
    final vendor = findVendor(slot.vendorId);
    // ⚠️ cast安全：先转List<LlmModel?>再firstWhere，避免运行时类型错误
    final model = (vendor?.models ?? []).cast<LlmModel?>().firstWhere((m) => m!.id == slot.modelId, orElse: () => vendor?.models.firstOrNull) ?? vendor?.models.firstOrNull;
    final url = _resolveUrl(slot);
    return Padding(key: key, padding: const EdgeInsets.only(bottom: 14), child: SlotGlassCard(slot: slot, index: index, isActive: isActive, isLast: index == _chain.slots.length - 1, vendor: vendor, model: model, url: url, primaryKey: _primaryKey, c: c,
      onUpdate: (s) => setState(() { final slots = List<LlmSlot>.from(_chain.slots); slots[index] = s; _chain = _chain.copyWith(slots: slots); }),
      onRemove: () => _removeSlot(index), onSetActive: () => _setActive(index)));
  }

  Widget _addButton(ThemeColors c) => Center(child: GestureDetector(onTap: _addSlot, child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16), border: Border.all(color: c.accent.withValues(alpha: 0.15))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_rounded, size: 18, color: c.accent), const SizedBox(width: 8), Text('添加模型', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.accent))]))));
  Widget _saveButton(ThemeColors c) => GestureDetector(onTap: _save, child: Container(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12), decoration: BoxDecoration(gradient: c.accentGradient, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]), child: const Text('保存全部', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))));
}

// ── Slot card widget ──

/// 槽位玻璃态卡片——单个模型槽位的UI组件
class SlotGlassCard extends StatefulWidget {
  final LlmSlot slot; final int index; final bool isActive; final bool isLast;
  final LlmVendor? vendor; final LlmModel? model; final String url;
  final String primaryKey; final ThemeColors c;
  final void Function(LlmSlot) onUpdate; final VoidCallback onRemove; final VoidCallback onSetActive;
  const SlotGlassCard({super.key, required this.slot, required this.index, required this.isActive, required this.isLast,
    required this.vendor, required this.model, required this.url, required this.primaryKey, required this.c,
    required this.onUpdate, required this.onRemove, required this.onSetActive});
  @override
  State<SlotGlassCard> createState() => _SlotGlassCardState();
}

class _SlotGlassCardState extends State<SlotGlassCard> with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late String _vendorId, _modelId, _customUrl, _apiKey;
  late final AnimationController _expandCtrl;
  late final Animation<double> _expandAnim;

  @override
  void initState() {
    super.initState();
    _vendorId = widget.slot.vendorId; _modelId = widget.slot.modelId;
    _customUrl = widget.slot.customUrl ?? ''; _apiKey = widget.slot.apiKey ?? '';
    _expandCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _expandAnim = CurvedAnimation(parent: _expandCtrl, curve: Curves.easeInOutCubic);
  }
  @override
  void dispose() { _expandCtrl.dispose(); super.dispose(); }

  /// 发射更新事件给父组件 — 空字符串的customUrl/apiKey转为null存储
  void _emit() => widget.onUpdate(widget.slot.copyWith(vendorId: _vendorId, modelId: _modelId, customUrl: _customUrl.isEmpty ? null : _customUrl, apiKey: _apiKey.isEmpty ? null : _apiKey));
  void _toggle() { if (_expanded) { _expandCtrl.reverse(); } else { _expandCtrl.forward(); } setState(() => _expanded = !_expanded); }

  @override
  Widget build(BuildContext context) {
    final c = widget.c; final vendor = findVendor(_vendorId); final models = vendor?.models ?? []; final isCustom = _vendorId == 'custom';
    return Column(children: [
      ClipRRect(borderRadius: BorderRadius.circular(18), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10), child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(color: widget.isActive ? c.accent.withValues(alpha: 0.10) : c.glassBg, borderRadius: BorderRadius.circular(18), border: Border.all(color: widget.isActive ? c.accent.withValues(alpha: 0.35) : c.glassBorder, width: 0.5), boxShadow: widget.isActive ? [BoxShadow(color: c.accent.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 4))] : c.shadowCard),
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(8, 10, 12, 10), child: Row(children: [
            // 拖拽手柄 — ReorderableDragStartListener必须包裹用于拖拽的元素
            ReorderableDragStartListener(index: widget.index, child: Icon(Icons.drag_handle_rounded, size: 22, color: c.textTertiary)),
            const SizedBox(width: 4),
            // 活跃切换圆点 — 点击设置当前为活跃模型
            GestureDetector(onTap: widget.onSetActive, child: AnimatedContainer(duration: const Duration(milliseconds: 250), width: 16, height: 16, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(shape: BoxShape.circle, color: widget.isActive ? c.accent : Colors.transparent, border: Border.all(color: widget.isActive ? c.accent : c.textPlaceholder, width: 2)))),
            Expanded(child: Text(widget.slot.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textPrimary))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)), child: Text('${vendor?.name ?? '?'} · ${widget.model?.name ?? '?'}', style: TextStyle(fontSize: 11, color: c.accent, fontWeight: FontWeight.w500))),
            const SizedBox(width: 6),
            // 展开/折叠按钮 — 0.5圈旋转动画
            GestureDetector(onTap: _toggle, child: AnimatedRotation(turns: _expanded ? 0.5 : 0, duration: const Duration(milliseconds: 300), child: Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: c.textTertiary))),
            // 删除按钮 — 仅非第一槽位显示（至少保留一个主模型）
            if (widget.index > 0) ...[const SizedBox(width: 2), GestureDetector(onTap: widget.onRemove, child: Icon(Icons.close_rounded, size: 20, color: c.danger.withValues(alpha: 0.7)))],
          ])),
          // 可展开编辑区 — 使用SizeTransition保证平滑展开/折叠
          SizeTransition(sizeFactor: _expandAnim, axisAlignment: -1, child: Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: Column(children: [
            const SizedBox(height: 4),
            // 厂商下拉 — 切换厂商时自动选中第一个模型
            _dd('厂商', _vendorId, allVendors.map((v) => DropdownMenuItem(value: v.id, child: Text(v.name, style: TextStyle(fontSize: 14, color: c.textPrimary)))).toList(), (v) { setState(() { _vendorId = v!; final nv = findVendor(v); if (nv != null && nv.models.isNotEmpty) _modelId = nv.models.first.id; if (!isCustom) _customUrl = nv?.defaultUrl ?? ''; _emit(); }); }, c),
            const SizedBox(height: 12),
            if (models.isNotEmpty) _dd('模型', _modelId, models.map((m) => DropdownMenuItem(value: m.id, child: Text('${m.name}  (${_fmt(m.contextWindow)})', style: TextStyle(fontSize: 14, color: c.textPrimary)))).toList(), (v) { setState(() { _modelId = v!; _emit(); }); }, c),
            // 自定义厂商时显示模型ID输入框
            if (isCustom) ...[const SizedBox(height: 12), _tf('模型ID', _modelId, (v) { _modelId = v; _emit(); }, c)],
            const SizedBox(height: 12), _tf('API 地址', _customUrl, (v) { _customUrl = v; _emit(); }, c),
            const SizedBox(height: 12), _tf('API Key (留空继承主)', _apiKey, (v) { _apiKey = v; _emit(); }, c),
          ]))),
        ])))),
      // 槽位间连接箭头 — 最后一项不显示
      if (!widget.isLast) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Icon(Icons.arrow_downward_rounded, size: 16, color: c.accent.withValues(alpha: 0.3))),
    ]);
  }

  /// ⚠️ 修复：DropdownButton需要深色背景以满足设置UI铁律
  Widget _dd(String l, String v, List<DropdownMenuItem<String>> items, ValueChanged<String?> cb, ThemeColors c) {
    final fill = c.bgCard.withValues(alpha: 0.5);
    return Row(children: [SizedBox(width: 52, child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary))), const SizedBox(width: 10), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.glassBorder)), child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: v, isExpanded: true, items: items, onChanged: cb, style: TextStyle(fontSize: 14, color: c.textPrimary), dropdownColor: c.bgCard, borderRadius: BorderRadius.circular(12)))))))]);
  }

  /// 文本输入框 — 使用TextEditingController的临时实例，onChanged直接写回
  ///
  /// ⚠️ 已知坑：每帧重建TextEditingController不会泄漏因为Flutter在build中创建的
  /// controller若不存储引用会被GC回收，但selection设置确保了光标位置正确。
  /// 更好的做法是提取为独立StatefulWidget管理controller生命周期。
  Widget _tf(String l, String v, ValueChanged<String> cb, ThemeColors c) {
    final fill = c.bgCard.withValues(alpha: 0.5);
    return Row(children: [SizedBox(width: 52, child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textSecondary))), const SizedBox(width: 10), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4), child: TextField(controller: TextEditingController(text: v)..selection = TextSelection.collapsed(offset: v.length), style: TextStyle(fontSize: 14, color: c.textPrimary), decoration: InputDecoration(contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), filled: true, fillColor: fill), onChanged: cb))))]);
  }

  /// 格式化上下文窗口大小 — ≥1M显示M，否则显示K
  String _fmt(int t) => t >= 1000000 ? '${t ~/ 1000000}M' : '${t ~/ 1000}K';
}
