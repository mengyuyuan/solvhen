/// Solvhen — 自定义人格设置页：人格叠加管理 + 玻璃态UI
///
/// 人格系统架构：
/// - 基底人格（Solvhen完整人格）始终生效，不可删除
/// - 自定义人格叠加在基底之上，通过active标志激活
/// - 同时只能激活一个人格（null=仅基底）
/// - 人格包含name（名称）和prompt（提示词），通过PromptBuilder注入system prompt
library;
import 'dart:ui';
import 'package:flutter/material.dart'; import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/persona.dart'; import '../services/database_service.dart'; import '../theme/theme_provider.dart';
import 'webview_canvas.dart';

/// 人格设置页——自定义人格的创建/编辑/激活
class SettingsPersonaPage extends ConsumerStatefulWidget { const SettingsPersonaPage({super.key}); @override ConsumerState<SettingsPersonaPage> createState() => _State(); }
class _State extends ConsumerState<SettingsPersonaPage> with TickerProviderStateMixin {
  bool _loaded = false; List<Persona> _personas = []; Persona? _active; late final AnimationController _entry;
  @override void initState() { super.initState(); _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 400)); _load(); }
  @override void dispose() { _entry.dispose(); super.dispose(); }

  /// 加载人格列表 + 当前激活人格 — 并行查询提高效率
  Future<void> _load() async {
    try {
      final r = await Future.wait([DB.getPersonas(), DB.getActivePersona()]);
      _personas = r[0] as List<Persona>;
      _active = r[1] as Persona?;
    } catch (_) { _personas = []; }
    setState(() => _loaded = true);
    _entry.forward();
  }

  /// 激活指定人格 — null表示回退到基底人格
  Future<void> _setActive(Persona? p) async {
    await DB.activatePersona(p?.id);
    setState(() => _active = p);
  }

  /// 删除人格 — 如果删除的是当前激活的则回退到基底
  Future<void> _delete(Persona p) async {
    await DB.deletePersona(p.id!);
    if (_active?.id == p.id) _active = null;
    await _load();
  }

  /// 新建/编辑人格对话框
  ///
  /// [existing] 不为null时为编辑模式，预填现有name和prompt
  void _addOrEdit({Persona? existing}) {
    final nc = TextEditingController(text: existing?.name ?? '');
    final pc = TextEditingController(text: existing?.prompt ?? '');
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text(existing != null ? '编辑人格' : '新建人格'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nc, decoration: const InputDecoration(hintText: '人格名称'), autofocus: true),
        const SizedBox(height: 12),
        TextField(controller: pc, decoration: const InputDecoration(hintText: '人格提示词'), maxLines: 5),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () async {
          final n = nc.text.trim();
          if (n.isEmpty) return;
          if (existing != null) {
            await DB.updatePersona(existing.id!, name: n, prompt: pc.text.trim());
          } else {
            await DB.createPersona(name: n, prompt: pc.text.trim());
          }
          Navigator.pop(ctx);
          await _load(); // 重新加载列表以显示更新
        }, child: const Text('保存'))
      ],
    ));
  }

  Widget _h(String t, ThemeColors c) => Text(t, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.textPrimary, letterSpacing: -0.3));
  Widget _glass(List<Widget> ch, ThemeColors c) => ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: c.glassBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.glassBorder, width: 0.5), boxShadow: c.shadowGlass), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: ch))));

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    if (!_loaded) return Container(decoration: BoxDecoration(gradient: c.bgGradient), child: const Center(child: CircularProgressIndicator(color: Color(0xFF5856D6))));
    return FadeTransition(opacity: CurvedAnimation(parent: _entry, curve: Curves.easeOut), child: Scaffold(backgroundColor: c.bgRoot,
      appBar: AppBar(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, title: Text('自定义人格', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary))),
      body: Stack(children: [const IgnorePointer(child: WebViewCanvas()), ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        _h('自定义人格', c),
        // 说明文字 — 强调叠加机制，不是替换
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 16), child: Text('叠加在 Solvhen 基底人格之上的场景化指令', style: TextStyle(fontSize: 12, color: c.textTertiary))),
        _glass([
          // 基底人格选项 — 始终可选，active=null时选中
          _tile(null, '基底人格（无叠加）', 'Solvhen 完整人格：理性、怜悯、锋芒兼具', _active == null, () => _setActive(null), c),
          if (_personas.isNotEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider()),
          // 自定义人格列表 — 单选、可编辑、可删除
          ...List.generate(_personas.length, (i) {
            final p = _personas[i];
            return _tile(p, p.name, p.prompt.isEmpty ? '（无描述）' : p.prompt, p.id == _active?.id, () => _setActive(p), c, onEdit: () => _addOrEdit(existing: p), onDelete: () => _delete(p));
          }),
          const SizedBox(height: 10),
          _outline('新建人格', Icons.add_rounded, () => _addOrEdit(), c),
        ], c),
      ])])));
  }

  /// 人格选择瓷砖 — 单选圆点 + 名称 + 描述截断(60字) + 编辑/删除按钮
  ///
  /// [p] 人格对象，null=基底, [active] 是否选中, [onEdit]/[onDelete] 可选操作
  Widget _tile(Persona? p, String name, String desc, bool active, VoidCallback onTap, ThemeColors c, {VoidCallback? onEdit, VoidCallback? onDelete}) {
    final d = desc.length > 60 ? '${desc.substring(0, 60)}...' : desc;
    return GestureDetector(onTap: onTap, child: AnimatedContainer(duration: const Duration(milliseconds: 250), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: active ? c.accent.withValues(alpha: 0.08) : Colors.transparent, borderRadius: BorderRadius.circular(14), border: active ? Border.all(color: c.accent.withValues(alpha: 0.2)) : null), child: Row(children: [
      AnimatedContainer(duration: const Duration(milliseconds: 250), width: 16, height: 16, margin: const EdgeInsets.only(right: 12), decoration: BoxDecoration(shape: BoxShape.circle, color: active ? c.accent : Colors.transparent, border: Border.all(color: active ? c.accent : c.textPlaceholder, width: 2))),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary)), const SizedBox(height: 2), Text(d, style: TextStyle(fontSize: 12, color: c.textTertiary))])),
      if (onEdit != null) GestureDetector(onTap: onEdit, child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.edit_rounded, size: 16, color: c.textTertiary))),
      if (onDelete != null) GestureDetector(onTap: onDelete, child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.delete_outline_rounded, size: 16, color: c.danger.withValues(alpha: 0.7)))),
    ])));
  }

  Widget _outline(String t, IconData i, VoidCallback cb, ThemeColors c) => GestureDetector(onTap: cb, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16), border: Border.all(color: c.accent.withValues(alpha: 0.15))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 16, color: c.accent), const SizedBox(width: 8), Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent))])));
}
