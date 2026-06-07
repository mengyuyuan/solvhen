/// Solvhen — 关于页面：品牌信息 + 版本更新日志 + 玻璃态
///
/// 纯展示页面，无交互逻辑。使用硬编码_changelog列表驱动渲染。
library;
import 'dart:ui';
import 'package:flutter/material.dart'; import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_provider.dart';
import 'webview_canvas.dart';

/// 关于页面——版本信息+更新日志
class SettingsAboutPage extends ConsumerStatefulWidget { const SettingsAboutPage({super.key}); @override ConsumerState<SettingsAboutPage> createState() => _State(); }
class _State extends ConsumerState<SettingsAboutPage> with TickerProviderStateMixin {
  late final AnimationController _entry;

  /// 更新日志 — (版本号, [功能列表])
  /// 新版本添加到列表头部即可
  /// ⚠️ 当前硬编码，后续应改为从asset JSON或远程配置加载
  static const _log = [
    ('v2.2.0', ['主动消息稳定性修复（Timer心跳+错误日志）', '设置页显示上次主动消息时间', '关于页更新日志', 'OTA 静默检查']),
    ('v2.1.0', ['主动消息（Timer + Wakelock 保活）', 'OTA 在线更新系统', '火山引擎 TTS/STT 修复', 'DSML 工具调用解析修复']),
    ('v1.1.0', ['玻璃态 Apple 风格', 'LLM 模型链：11厂商，拖拽排序，顺序降级', 'TTS 五引擎：火山/Edge/OpenAI/GPT-SoVITS/自定义', '图片+视频模型槽位']),
    ('v1.0.0', ['动态背景粒子/网格/光环', 'WebView画布 render_html', 'AI自由修改UI', '斜杠命令 /new /clear /theme', '28工具']),
  ];

  @override void initState() { super.initState(); _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 400)); _entry.forward(); }
  @override void dispose() { _entry.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    return FadeTransition(opacity: CurvedAnimation(parent: _entry, curve: Curves.easeOut), child: Scaffold(backgroundColor: c.bgRoot,
      appBar: AppBar(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, title: Text('关于 Solvhen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary))),
      body: Stack(children: [const IgnorePointer(child: WebViewCanvas()), ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        // 品牌区域
        Text('Solvhen', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: c.textPrimary, letterSpacing: -0.5)),
        Padding(padding: const EdgeInsets.only(top: 2, bottom: 24), child: Text('世于我愿 · 手机智能体', style: TextStyle(fontSize: 14, color: c.accent, fontWeight: FontWeight.w500))),
        // 更新日志标题
        Text('更新日志', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: c.textPrimary, letterSpacing: -0.3)),
        const SizedBox(height: 14),
        // 版本卡片列表 — 每个版本一个玻璃态卡片
        ..._log.map((e) => Padding(padding: const EdgeInsets.only(bottom: 14), child: ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: c.glassBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.glassBorder, width: 0.5), boxShadow: c.shadowGlass), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.$1, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.accent)),
          const SizedBox(height: 8),
          ...e.$2.map((l) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('· $l', style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.5))))
        ])))))),
      ])])));
  }
}
