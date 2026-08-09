/// Solvhen 设置主页：点阵科技、克制浅玻璃、分区式 push 导航。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/security/tool_security.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';
import 'settings_about_page.dart';
import 'settings_agent_page.dart';
import 'settings_developer_page.dart';
import 'settings_image_page.dart';
import 'settings_llm_page.dart';
import 'settings_onebot_page.dart';
import 'settings_persona_page.dart';
import 'settings_profile_page.dart';
import 'settings_security_page.dart';
import 'settings_tts_page.dart';
import 'settings_update_page.dart';
import 'settings_video_page.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entry;
  late final List<Animation<double>> _animations;
  StreamSubscription<bool>? _securitySubscription;

  static const _items = [
    (
      section: '账户与安全',
      icon: Icons.person_outline_rounded,
      title: '个人设置',
      subtitle: '主动消息 · 偏好',
    ),
    (
      section: '账户与安全',
      icon: Icons.security_outlined,
      title: '安全中心',
      subtitle: '能力开关 · 来源隔离 · 工具审计',
    ),
    (
      section: '能力与模型',
      icon: Icons.account_tree_outlined,
      title: 'Agent 运行',
      subtitle: '步数 · 循环 · 截止时间',
    ),
    (
      section: '能力与模型',
      icon: Icons.psychology_outlined,
      title: 'LLM 模型',
      subtitle: '模型链 · 降级策略 · 多厂商',
    ),
    (
      section: '能力与模型',
      icon: Icons.record_voice_over_outlined,
      title: 'TTS 语音',
      subtitle: '引擎 · 音色 · 克隆',
    ),
    (
      section: '能力与模型',
      icon: Icons.image_outlined,
      title: '图片生成',
      subtitle: '147ai · DALL-E · ComfyUI',
    ),
    (
      section: '能力与模型',
      icon: Icons.movie_creation_outlined,
      title: '视频生成',
      subtitle: 'Kling · Runway · ComfyUI',
    ),
    (
      section: '能力与模型',
      icon: Icons.face_outlined,
      title: '自定义人格',
      subtitle: '场景叠加 · 基底不替换',
    ),
    (
      section: '连接与系统',
      icon: Icons.hub_outlined,
      title: 'QQ/微信 桥接',
      subtitle: 'OneBot · NapCatQQ · 自动回复',
    ),
    (
      section: '连接与系统',
      icon: Icons.system_update_alt_rounded,
      title: '检查更新',
      subtitle: '签名校验 · OTA 在线更新',
    ),
    (
      section: '连接与系统',
      icon: Icons.terminal_rounded,
      title: '开发者模式',
      subtitle: '私网配对 · 自重建通道 · 默认锁定',
    ),
    (
      section: '连接与系统',
      icon: Icons.info_outline_rounded,
      title: '关于 Solvhen',
      subtitle: '版本 · 更新日志',
    ),
  ];

  static const _pages = [
    SettingsProfilePage(),
    SettingsSecurityPage(),
    SettingsAgentPage(),
    SettingsLlmPage(),
    SettingsTtsPage(),
    SettingsImagePage(),
    SettingsVideoPage(),
    SettingsPersonaPage(),
    SettingsOneBotPage(),
    SettingsUpdatePage(),
    SettingsDeveloperPage(),
    SettingsAboutPage(),
  ];

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _animations = List.generate(
      _items.length,
      (index) => CurvedAnimation(
        parent: _entry,
        curve: Interval(
          index / (_items.length + 2),
          1,
          curve: Curves.easeOutCubic,
        ),
      ),
    );
    _securitySubscription = SecuritySession.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _entry.forward();
  }

  @override
  void dispose() {
    _securitySubscription?.cancel();
    _entry.dispose();
    super.dispose();
  }

  Future<void> _open(int index) async {
    if (index < 0 || index >= _pages.length) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => _pages[index],
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.025, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 260),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _animated(int index, Widget child) {
    return FadeTransition(
      opacity: _animations[index],
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.045),
          end: Offset.zero,
        ).animate(_animations[index]),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    return Scaffold(
      backgroundColor: colors.bgRoot,
      appBar: AppBar(
        title: Text(
          '设置',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: SolvhenDotField(color: colors.dotColor)),
          ListView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
            children: _buildItems(colors),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildItems(ThemeColors colors) {
    final widgets = <Widget>[
      SolvhenPanel(
        colors: colors,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: colors.accentSoft,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.22),
                ),
              ),
              child: Icon(
                Icons.shield_outlined,
                color: colors.accent,
                size: 21,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本地控制中心',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '密钥与数据默认留在此设备',
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            SolvhenTag(
              colors: colors,
              label: 'LOCAL FIRST',
              icon: Icons.lock_outline_rounded,
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
    ];

    String? currentSection;
    for (var index = 0; index < _items.length; index++) {
      final item = _items[index];
      if (item.section != currentSection) {
        if (currentSection != null) widgets.add(const SizedBox(height: 10));
        currentSection = item.section;
        widgets.add(
          SolvhenSectionLabel(
            colors: colors,
            label: currentSection,
          ),
        );
      }
      widgets.add(
        _animated(
          index,
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: _tile(
              item.icon,
              item.title,
              item.subtitle,
              () => _open(index),
              colors,
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _tile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
    ThemeColors colors,
  ) {
    final securityTile = title == '安全中心';
    final trusted = SecuritySession.instance.trusted;
    final iconColor = securityTile
        ? (trusted ? colors.warning : colors.success)
        : colors.navy;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SolvhenPanel(
          colors: colors,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: iconColor.withValues(
                    alpha: colors.isDark ? 0.18 : 0.08,
                  ),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.18),
                  ),
                ),
                child: Icon(icon, size: 21, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (securityTile) ...[
                SolvhenTag(
                  colors: colors,
                  label: trusted ? 'TRUST' : 'SAFE',
                  color: iconColor,
                ),
                const SizedBox(width: 5),
              ],
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
