import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';
import '../theme/solvhen_design.dart';
import '../theme/theme_provider.dart';
import 'settings_llm_page.dart';

class AppLaunchGate extends ConsumerStatefulWidget {
  const AppLaunchGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLaunchGate> createState() => _AppLaunchGateState();
}

class _AppLaunchGateState extends ConsumerState<AppLaunchGate> {
  bool? _showOnboarding;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    var show = false;
    try {
      show = await DB.shouldShowOnboarding();
    } catch (_) {
      // Database errors are surfaced by the chat screen. Never trap an
      // existing user behind onboarding when detection itself fails.
    }
    if (mounted) setState(() => _showOnboarding = show);
  }

  Future<void> _finish() async {
    await DB.completeOnboarding();
    if (mounted) setState(() => _showOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    if (_showOnboarding == null) {
      return Scaffold(
        backgroundColor: colors.bgRoot,
        body: Stack(
          children: [
            Positioned.fill(child: SolvhenDotField(color: colors.dotColor)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SolvhenMatrixMark(colors: colors, width: 30, height: 30),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 28,
                    child: LinearProgressIndicator(
                      color: colors.accent,
                      backgroundColor: colors.separator,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (_showOnboarding == true) {
      return _OnboardingScreen(onFinish: _finish);
    }
    return widget.child;
  }
}

class _OnboardingScreen extends ConsumerStatefulWidget {
  const _OnboardingScreen({required this.onFinish});

  final Future<void> Function() onFinish;

  @override
  ConsumerState<_OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<_OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  bool _finishing = false;

  static const _pages = [
    _OnboardingData(
      eyebrow: 'SOLVHEN · LOCAL AGENT',
      title: '你的模型，\n你的设备，\n你的数据。',
      detail: 'Solvhen 是运行在手机上的 AI Agent。默认不上传遥测，数据和记忆保存在本机。',
      icon: Icons.blur_on_rounded,
      points: ['用户自带模型 Key', '对话与记忆本地保存', '无自动遥测'],
    ),
    _OnboardingData(
      eyebrow: 'PERMISSION · ON DEMAND',
      title: '需要时，\n再申请权限。',
      detail: '首次启动不会索取全部系统权限。使用语音、通知或文件能力时，Solvhen 会解释用途后再请求。',
      icon: Icons.admin_panel_settings_outlined,
      points: ['拒绝权限仍可离线启动', '可在系统设置随时撤回', '能力开关独立控制工具'],
    ),
    _OnboardingData(
      eyebrow: 'POLICY · CONFIRM FIRST',
      title: '能做事，\n也知道边界。',
      detail: '安全模式默认开启。普通修改会先询问；不可逆操作在任何模式下都必须逐次确认。',
      icon: Icons.verified_user_outlined,
      points: ['默认只读自动执行', '信任模式仅当前进程', '发送、删除、安装和系统设置总是确认'],
    ),
    _OnboardingData(
      eyebrow: 'BYOK · OPENAI COMPATIBLE',
      title: '连接模型，\n开始工作。',
      detail: '支持 DeepSeek、OpenAI、Claude、豆包及兼容接口。Key 将迁移到 Android 安全存储。',
      icon: Icons.key_rounded,
      points: ['模型链与自动降级', '可稍后在设置中配置', '费用由你的模型服务商计费'],
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_page < _pages.length - 1) {
      await _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    await _finish();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onFinish();
  }

  Future<void> _configureModel() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsLlmPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ThemeColors(ref.watch(themeProvider));
    final last = _page == _pages.length - 1;
    return Scaffold(
      backgroundColor: colors.bgRoot,
      body: Stack(
        children: [
          Positioned.fill(child: SolvhenDotField(color: colors.dotColor)),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 14, 4),
                  child: Row(
                    children: [
                      SolvhenMatrixMark(colors: colors, width: 28, height: 28),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SOLVHEN',
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                          Text(
                            'PUBLIC BETA · LOCAL FIRST',
                            style: TextStyle(
                              color: colors.textPlaceholder,
                              fontFamily: 'monospace',
                              fontSize: 8,
                              letterSpacing: 0.7,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _finishing ? null : _finish,
                        child: const Text('跳过'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _pages.length,
                    onPageChanged: (value) => setState(() => _page = value),
                    itemBuilder: (_, index) => _OnboardingPage(
                      data: _pages[index],
                      colors: colors,
                      index: index,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            '${(_page + 1).toString().padLeft(2, '0')} / '
                            '${_pages.length.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              color: colors.textTertiary,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              children: List.generate(
                                _pages.length,
                                (index) => Expanded(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 220),
                                    height: 3,
                                    margin: EdgeInsets.only(
                                      right: index == _pages.length - 1 ? 0 : 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: index <= _page
                                          ? colors.accent
                                          : colors.separator,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (last) ...[
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _configureModel,
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('先配置模型'),
                          ),
                        ),
                        const SizedBox(height: 9),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: _finishing ? null : _next,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(last ? '进入 Solvhen' : '继续'),
                              const SizedBox(width: 8),
                              if (_finishing)
                                const SizedBox.square(
                                  dimension: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              else
                                const Icon(Icons.arrow_forward_rounded,
                                    size: 18),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.data,
    required this.colors,
    required this.index,
  });

  final _OnboardingData data;
  final ThemeColors colors;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.eyebrow,
            style: TextStyle(
              color: colors.accent,
              fontFamily: 'monospace',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.05,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            data.title,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 35,
              height: 1.12,
              letterSpacing: -1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            data.detail,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
              height: 1.65,
            ),
          ),
          const SizedBox(height: 26),
          Expanded(
            child: SolvhenPanel(
              colors: colors,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: colors.accentSoft,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Icon(data.icon, color: colors.accent, size: 23),
                      ),
                      const Spacer(),
                      Text(
                        '0${index + 1}',
                        style: TextStyle(
                          color: colors.textPlaceholder,
                          fontFamily: 'monospace',
                          fontSize: 24,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  for (final point in data.points)
                    Padding(
                      padding: const EdgeInsets.only(top: 11),
                      child: Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: colors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              point,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingData {
  const _OnboardingData({
    required this.eyebrow,
    required this.title,
    required this.detail,
    required this.icon,
    required this.points,
  });

  final String eyebrow;
  final String title;
  final String detail;
  final IconData icon;
  final List<String> points;
}
