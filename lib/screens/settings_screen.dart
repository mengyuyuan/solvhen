/// Solvhen — 设置主页面：iOS风格竖排列表 + 玻璃态卡片，底部WebView画布背景
///
/// 架构：垂直ListView，6个设置入口卡片（LLM/TTS/图片/视频/人格/关于），
/// 每个卡片通过PageRouteBuilder push子页面，带入场动画。
library;

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_provider.dart';
import 'webview_canvas.dart';
import 'settings_llm_page.dart';
import 'settings_tts_page.dart';
import 'settings_image_page.dart';
import 'settings_video_page.dart';
import 'settings_persona_page.dart';
import 'settings_about_page.dart';
import 'settings_onebot_page.dart';
import 'settings_profile_page.dart';
import 'settings_update_page.dart';

/// 设置主页面——各设置模块入口导航
/// UI设计：竖排列表+玻璃态卡片+push导航，禁用TabBar
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with TickerProviderStateMixin {
  late final AnimationController _entry;       // 入场动画控制器（700ms）
  late final List<Animation<double>> _anims;   // 每个卡片独立的错峰动画

  // 6个设置入口 — icon + 标题 + 副标题
  static const _items = [
    (icon: Icons.person_rounded, title: '个人设置', subtitle: '主动消息 · 偏好'),
    (icon: Icons.psychology_rounded, title: 'LLM 模型', subtitle: '模型链 · 降级策略 · 多厂商'),
    (icon: Icons.record_voice_over_rounded, title: 'TTS 语音', subtitle: '引擎 · 音色 · 克隆'),
    (icon: Icons.image_rounded, title: '图片生成', subtitle: '147ai · DALL-E · ComfyUI'),
    (icon: Icons.movie_creation_rounded, title: '视频生成', subtitle: 'Kling · Runway · ComfyUI'),
    (icon: Icons.face_rounded, title: '自定义人格', subtitle: '场景叠加 · 基底不替换'),
    (icon: Icons.chat_rounded, title: 'QQ/微信 桥接', subtitle: 'OneBot · NapCatQQ · 自动回复'),
    (icon: Icons.system_update_rounded, title: '检查更新', subtitle: 'OTA 在线更新'),
    (icon: Icons.info_outline_rounded, title: '关于 Solvhen', subtitle: '更新日志'),
  ];

  static const _pages = [
    SettingsProfilePage(),
    SettingsLlmPage(),
    SettingsTtsPage(),
    SettingsImagePage(),
    SettingsVideoPage(),
    SettingsPersonaPage(),
    SettingsOneBotPage(),
    SettingsUpdatePage(),
    SettingsAboutPage(),
  ];

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    // 错峰入场：每个卡片延迟 i/n 比例开始，产生依次滑入效果
    _anims = List.generate(_items.length, (i) =>
      CurvedAnimation(parent: _entry, curve: Interval(i / _items.length, 1.0, curve: Curves.easeOutCubic)));
    _entry.forward();
  }

  @override
  void dispose() { _entry.dispose(); super.dispose(); }

  /// 推入子设置页 — 使用PageRouteBuilder自定义转场动画（淡入，300ms）
  void _open(int i) {
    // 安全边界：当i越界时回退，防止_cItems/_pages数组长度不一致时崩溃
    if (i < 0 || i >= _pages.length) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => _pages[i],
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  /// 包裹入场动画：透明度+轻微上滑（6%偏移→归位）
  Widget _f(int i, Widget w) => FadeTransition(
    opacity: _anims[i],
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(_anims[i]),
      child: w,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
        // 直接使用bgRoot，符合设置UI铁律：Scaffold背景不使用额外Container包裹
        backgroundColor: c.bgRoot,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent, // Material 3 水波纹色消除
          title: Text('设置', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: c.textPrimary, letterSpacing: -0.5)),
        ),
        body: Stack(children: [
          // WebView画布背景层 — IgnorePointer确保不拦截触摸事件
          const IgnorePointer(child: WebViewCanvas()),
          // 竖排列表 — 符合设置UI铁律：不使用TabBar，纯push导航
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              return _f(i, Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _tile(item.icon, item.title, item.subtitle, () => _open(i), c),
              ));
            }),
            ),
            ]),
            );
  }

  /// 玻璃态设置卡片：毛玻璃背景 + 主题色渐变图标 + 右箭头
  ///
  /// [icon] 左侧图标, [title] 标题, [subtitle] 副标题, [onTap] 点击回调, [c] 主题色
  Widget _tile(IconData icon, String title, String subtitle, VoidCallback onTap, ThemeColors c) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        // ⚠️ BackdropFilter性能坑：sigmaX/Y=12会触发逐帧高斯模糊，低端机可降至8
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.glassBg,                    // 半透明玻璃底色
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: c.glassBorder, width: 0.5), // 0.5px细边框 — 玻璃态关键
              boxShadow: c.shadowCard,
            ),
            child: Row(children: [
              // 图标容器 — 主题渐变色背景
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [c.accent, c.accent.withValues(alpha: 0.7)]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 22, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(fontSize: 13, color: c.textTertiary)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, size: 22, color: c.textPlaceholder),
            ]),
          ),
        ),
      ),
      );
  }
}
