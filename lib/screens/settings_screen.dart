import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_provider.dart';
import '../services/database_service.dart';
import '../models/persona.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _loaded = false;
  bool _hideKey = true;

  List<Persona> _personas = [];
  Persona? _activePersona;

  // Changelog — update this with each release
  static const _changelog = [
    ('核心功能', [
      '🖐 系统控制：电池/音量/亮度读写，WiFi/蓝牙/手电筒开关，响铃模式/锁屏/屏幕常亮',
      '📱 应用管理：列出手机上所有已装应用，通过包名或中文名打开任意App',
      '📁 文件系统：沙箱内文件读写（带行号分页），浏览手机任意文件夹（Download/DCIM等）',
      '🌐 网络搜索：Bing+百度+搜狗三引擎并行，网页内容提取去HTML，fetch_url抓取',
      '🧠 记忆系统：跨对话记住你的名字/偏好/重要事实，对话自动整合提取',
      '🎭 人格系统：完整基底人格（理性·怜悯·求知欲）+ 自定义叠加层',
      '🤖 子Agent：delegate_task并行委派多个子分身处理复杂任务',
    ]),
    ('界面与交互', [
      '👁 动态头像：16帧手绘PNG表情，10个眼球方向，6帧眨眼序列，8状态动画引擎',
      '🎨 动态背景：粒子系统/透视网格/脉冲光环/扫描线/Canvas绘制原语（模糊+混合模式）',
      '🖼 WebView画布：render_html全屏HTML/CSS渲染，持久化保存，重启恢复',
      '✨ 表情控制：draw_expression画表情，animate关键帧动画，spawn_particle粒子',
      '⌨ 斜杠命令：/new /clear /theme /volume /brightness /wifi 等快捷操作',
    ]),
    ('智能特性', [
      '🔧 28个工具：系统/主题/文件/网络/代码/记忆/历史/UI/委派，动态注册',
      '🔄 自我进化：rebuild_self修改自身渲染代码→编译→安装→重启生效',
      '📊 实时上下文条：token使用率显示，CJK精确估算（1.5x），模型窗口自适应',
      '💬 多对话管理：抽屉切换/新建/删除对话，SQLite+FTS5全文搜索',
      '🔒 安全：路径白名单/SSRF防护/Shell注入修复/FTS5转义/工具循环保护',
    ]),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        DB.getConfig(),
        DB.getPersonas(),
        DB.getActivePersona(),
      ]);
      final c = results[0] as Map<String, String>;
      _urlCtrl.text = c['base_url'] ?? 'https://api.deepseek.com/v1';
      _keyCtrl.text = c['api_key'] ?? '';
      _modelCtrl.text = c['model'] ?? 'deepseek-v4-pro';
      _personas = results[1] as List<Persona>;
      _activePersona = results[2] as Persona?;
    } catch (e) {
      // If DB reads fail, still show UI (config fields empty, no personas)
      _personas = [];
      _activePersona = null;
      debugPrint('Settings _load error: $e');
    }
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    try {
      final db = await DB.database;
      await db.transaction((txn) async {
        await txn.rawInsert(
          'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
          ['base_url', _urlCtrl.text.trim()],
        );
        await txn.rawInsert(
          'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
          ['api_key', _keyCtrl.text.trim()],
        );
        await txn.rawInsert(
          'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
          ['model', _modelCtrl.text.trim()],
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _preset(String label, String url, String model) {
    _urlCtrl.text = url;
    _modelCtrl.text = model;
    _save().catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('预设保存失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    });
  }

  Future<void> _activatePersona(Persona? p) async {
    await DB.activatePersona(p?.id);
    setState(() => _activePersona = p);
  }

  Future<void> _addPersona() async {
    final nameCtrl = TextEditingController();
    final promptCtrl = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建人格'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '人格名称', hintText: '给这个人格起个名字',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: promptCtrl,
                maxLines: 5, minLines: 3,
                decoration: const InputDecoration(
                  labelText: '人格描述', hintText: '描述你要叠加的行为、语气、规则...\n这些会追加在Solvhen基底人格之上。',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {'name': nameCtrl.text.trim(), 'prompt': promptCtrl.text.trim()}),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != null && (result['name'] as String?)?.trim().isNotEmpty == true) {
      await DB.createPersona(name: (result['name'] as String).trim(), prompt: result['prompt'] ?? '');
      _personas = await DB.getPersonas();
      setState(() {});
    }
  }

  Future<void> _editPersona(Persona p) async {
    final nameCtrl = TextEditingController(text: p.name);
    final promptCtrl = TextEditingController(text: p.prompt);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑人格'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '人格名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: promptCtrl,
                maxLines: 5, minLines: 3,
                decoration: const InputDecoration(
                  labelText: '人格描述',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {'name': nameCtrl.text.trim(), 'prompt': promptCtrl.text.trim()}),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && (result['name'] as String?)?.trim().isNotEmpty == true && p.id != null) {
      await DB.updatePersona(p.id!, name: (result['name'] as String).trim(), prompt: result['prompt']);
      _personas = await DB.getPersonas();
      _activePersona = await DB.getActivePersona();
      setState(() {});
    }
  }

  @override
  void dispose() { _urlCtrl.dispose(); _keyCtrl.dispose(); _modelCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final c = ThemeColors(ref.watch(themeProvider));

    return Scaffold(
      backgroundColor: c.bgRoot,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // ── 自定义人格 ──
        const Text('自定义人格', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF8E8E93))),
        const SizedBox(height: 4),
        Text(
          'Solvhen拥有完整的基底人格。自定义人格作为叠加层——为特定场景追加指令，不替换基底。',
          style: TextStyle(fontSize: 11, color: c.textTertiary),
        ),
        const SizedBox(height: 12),
        _card([
          // Active: none (base only)
          _personaTile(null, '基底人格（无叠加）', 'Solvhen的完整人格：理性、怜悯、锋芒兼具', c,
              active: _activePersona == null),

          const SizedBox(height: 4),
          if (_personas.isNotEmpty) ...[
            ..._personas.map((p) => _personaTile(
              p, p.name, p.prompt.isEmpty ? '（无描述）' : p.prompt,
              c, active: p.id == _activePersona?.id,
            )),
            const SizedBox(height: 4),
          ],

          // Add persona button
          OutlinedButton.icon(
            onPressed: _addPersona,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建人格'),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.accent,
              side: BorderSide(color: c.accent.withValues(alpha: 0.3)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ], c),

        const SizedBox(height: 24),

        // ── API ──
        const Text('API 配置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF8E8E93))),
        const SizedBox(height: 12),
        _card([
          _field('API 地址', 'https://api.deepseek.com/v1', _urlCtrl, c),
          const SizedBox(height: 14),
          _field('API Key', 'sk-...', _keyCtrl, c, obscure: _hideKey, suffix: IconButton(
            icon: Icon(_hideKey ? Icons.visibility_off : Icons.visibility, size: 18, color: c.textTertiary),
            onPressed: () => setState(() => _hideKey = !_hideKey),
          )),
          const SizedBox(height: 14),
          _field('模型名称', 'deepseek-v4-pro', _modelCtrl, c),
          const SizedBox(height: 14),
          // Context window note
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 14, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '上下文窗口: ${_fmtContextWindow(_modelCtrl.text)}。聊天顶部会显示用量。',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip('DeepSeek V4 Pro', 'https://api.deepseek.com/v1', 'deepseek-v4-pro', c),
            _chip('DeepSeek V4 Flash', 'https://api.deepseek.com/v1', 'deepseek-v4-flash', c),
            _chip('DeepSeek R1', 'https://api.deepseek.com/v1', 'deepseek-reasoner', c),
            _chip('豆包', 'https://ark.cn-beijing.volces.com/api/v3', 'doubao-seed-2-0-pro-260215', c),
            _chip('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus', c),
            _chip('ChatGPT', 'https://api.openai.com/v1', 'gpt-4o-mini', c),
          ]),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(backgroundColor: c.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('保存'),
          )),
        ], c),

        const SizedBox(height: 24),

        // ── 更新日志 ──
        const Text('更新日志', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF8E8E93))),
        const SizedBox(height: 12),
        _card([
          for (final entry in _changelog)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.$1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent)),
                const SizedBox(height: 2),
                ...entry.$2.map((line) => Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text('• $line', style: TextStyle(fontSize: 12, color: c.textSecondary, height: 1.5)),
                )),
              ]),
            ),
        ], c),
      ]),
    );
  }

  String _fmtContextWindow(String model) {
    final tokens = DB.contextWindow(model);
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(0)}K tokens';
    return '$tokens tokens';
  }

  Widget _personaTile(Persona? p, String name, String desc, ThemeColors c, {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => _activatePersona(p),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: active ? c.accent.withValues(alpha: 0.08) : c.bgRoot,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? c.accent : c.separator, width: active ? 1.5 : 1),
          ),
          child: Row(children: [
            Icon(
              active ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20, color: active ? c.accent : c.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                    color: active ? c.accent : c.textPrimary)),
                Text(
                  desc.length > 60 ? '${desc.substring(0, 60)}…' : desc,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
              ]),
            ),
            if (p != null)
              InkWell(
                onTap: () => _editPersona(p),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.edit_outlined, size: 16, color: c.textTertiary),
                ),
              ),
            if (p != null)
              InkWell(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('删除人格'),
                      content: Text('确定删除「${p.name}」？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await DB.deletePersona(p.id!);
                    if (p.id == _activePersona?.id) {
                      await DB.activatePersona(null);
                      _activePersona = null;
                    }
                    _personas = await DB.getPersonas();
                    setState(() {});
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.delete_outline, size: 16, color: c.textTertiary),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _card(List<Widget> children, ThemeColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.bgCardSolid,
        borderRadius: BorderRadius.circular(16),
        boxShadow: c.shadowSm,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _field(String label, String hint, TextEditingController ctrl, ThemeColors c,
      {bool obscure = false, Widget? suffix, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.textSecondary)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        obscureText: obscure,
        maxLines: maxLines,
        minLines: 1,
        style: TextStyle(fontSize: 14, color: c.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 14, color: c.textPlaceholder),
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.separator)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.accent)),
          filled: true, fillColor: c.bgRoot,
        ),
      ),
    ]);
  }

  Widget _chip(String label, String url, String model, ThemeColors c) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: c.accent.withValues(alpha: 0.08),
      side: BorderSide.none,
      onPressed: () => _preset(label, url, model),
    );
  }
}
