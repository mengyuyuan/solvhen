// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主题管理器——动态主题状态管理，玻璃态/暗色/亮色主题切换+颜色系统
// ═══════════════════════════════════════════════════════════════

library;

/// Solvhen glassmorphism aesthetic: frosted panels, soft shadows, gradient washes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/database_service.dart' show DB;

/// 主题状态管理——玻璃态/暗色/亮色切换
/// ⚠️ _loaded必须在finally中设置（当前在try中，失败会导致无限重试）
class ThemeNotifier extends ChangeNotifier {
  static final ThemeNotifier _instance = ThemeNotifier._();
  factory ThemeNotifier() => _instance;
  ThemeNotifier._();

  ThemeState _state = const ThemeState();
  ThemeState get state => _state;
  bool _loaded = false;

  Future<void> loadFromDB() async {
    if (_loaded) return;
    try {
      final cfg = await DB.getConfig();
      final accentHex = cfg['theme_accent'];
      final brightnessStr = cfg['theme_brightness'];
      if (accentHex != null && accentHex.isNotEmpty) {
        final h = accentHex.replaceFirst('#', '');
        final c = h.length == 8
            ? Color(int.parse(h, radix: 16))
            : Color(int.parse(h, radix: 16) | 0xFF000000);
        _state = ThemeState(accent: c, accentHex: accentHex,
          brightness: brightnessStr == 'dark' ? Brightness.dark : Brightness.light);
        notifyListeners();
      }
    } catch (_) {} finally { _loaded = true; }
  }

  bool setAccentColor(String hexOrName) {
    final hex = _resolve(hexOrName);
    if (hex == null) return false;
    try {
      final h = hex.replaceFirst('#', '');
      final c = h.length == 8 ? Color(int.parse(h, radix: 16)) : Color(int.parse(h, radix: 16) | 0xFF000000);
      _state = ThemeState(accent: c, accentHex: hex, brightness: _state.brightness);
      notifyListeners(); _persist(); return true;
    } catch (_) { return false; }
  }

  void setBrightness(String mode) {
    _state = ThemeState(accent: _state.accent, accentHex: _state.accentHex,
      brightness: mode == 'dark' ? Brightness.dark : Brightness.light);
    notifyListeners(); _persist();
  }

  void _persist() {
    DB.setConfig('theme_accent', _state.accentHex).catchError((e) => debugPrint('Theme persist: $e'));
    DB.setConfig('theme_brightness', _state.brightness == Brightness.dark ? 'dark' : 'light').catchError((e) => debugPrint('Theme persist: $e'));
  }

  static String? _resolve(String s) {
    final t = s.trim().toLowerCase();
    if (RegExp(r'^#?[0-9a-f]{6}$').hasMatch(t)) return t.startsWith('#') ? t : '#$t';
    const map = {
      'blue': '#007AFF', 'purple': '#AF52DE', 'green': '#34C759', 'pink': '#FF2D55', 'orange': '#FF9500',
      'red': '#FF3B30', 'teal': '#5AC8FA', 'mint': '#34C759', 'yellow': '#FFCC00', 'hotpink': '#FF69B4',
      'cyan': '#00BCD4', 'indigo': '#5856D6', 'coral': '#FF6B6B', 'black': '#1C1C1E', 'white': '#FFFFFF',
      'grey': '#8E8E93', 'gray': '#8E8E93', 'navy': '#001F3F', 'gold': '#FFD700', 'lavender': '#E6E6FA',
      'rose': '#FF007F', 'violet': '#8B5CF6', 'emerald': '#10B981', 'sky': '#38BDF8', 'magenta': '#FF00FF',
    };
    return map[t];
  }
}

class ThemeState {
  final Color accent; final String accentHex; final Brightness brightness;
  const ThemeState({this.accent = const Color(0xFF5856D6), this.accentHex = '#5856D6', this.brightness = Brightness.light});
}

/// 动态颜色系统——支持AI实时修改的语义色定义
/// 包含：背景/文字/强调/气泡/危险/警告/成功等50+颜色属性
class ThemeColors {
  final ThemeNotifier _n;
  ThemeColors(ThemeNotifier notifier) : _n = notifier;
  ThemeState get s => _n.state;
  Color get accent => s.accent;
  bool get isDark => s.brightness == Brightness.dark;

  // ── Cached values ──
  Color? _cBg, _cCard, _cHover;
  Brightness? _cBr; Color? _cAc;

  void _inv() {
    if (_cBr != s.brightness || _cAc != s.accent) {
      _cBg = null; _cCard = null; _cHover = null;
      _cBr = s.brightness; _cAc = s.accent;
    }
  }

  // ── Backgrounds ──
  Color get bgRoot { _inv(); _cBg ??= isDark ? const Color(0xFF0D0D12) : const Color(0xFFF2F2F7); return _cBg!; }
  Color get bgCard { _inv(); _cCard ??= isDark ? const Color(0xFF1A1A24) : Colors.white; return _cCard!; }
  // Legacy compat
  Color get bgCardSolid => bgCard;
  List<BoxShadow> get shadowSm => shadowCard;

  // Glass panel — translucent frosted surface (use with BackdropFilter)
  Color get glassBg => isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.78);
  Color get glassBorder => isDark ? Colors.white.withValues(alpha: 0.10) : const Color(0x33FFFFFF);
  Color get glassHover { _inv(); _cHover ??= isDark ? Colors.white.withValues(alpha: 0.10) : accent.withValues(alpha: 0.06); return _cHover!; }

  // Gradient wash — solid, clean ambient
  LinearGradient get bgGradient => LinearGradient(
    begin: Alignment.topCenter, end: Alignment.bottomCenter,
    colors: isDark
        ? [const Color(0xFF1A1A2E), const Color(0xFF0D0D12), const Color(0xFF0D0D12)]
        : [const Color(0xFFF8FAFC), const Color(0xFFF2F2F7), const Color(0xFFEDEEF0)],
  );

  // Accent gradient for buttons/badges
  LinearGradient get accentGradient => LinearGradient(
    colors: [accent, accent.withValues(alpha: 0.75)],
  );

  // ── Text ──
  Color get textPrimary => isDark ? Colors.white : const Color(0xFF1C1C1E);
  Color get textSecondary => isDark ? const Color(0xFF98989E) : const Color(0xFF6E6E73);
  Color get textTertiary => isDark ? const Color(0xFF636368) : const Color(0xFFAEAEB2);
  Color get textPlaceholder => const Color(0xFFC7C7CC);
  Color get textCaption => const Color(0xFF8E8E93);

  // ── Semantic ──
  Color get danger => const Color(0xFFFF3B30);
  Color get warning => const Color(0xFFFF9500);
  Color get success => const Color(0xFF34C759);
  Color get separator => isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFD1D1D6);

  // ── Shadows (glass multi-layer) ──
  List<BoxShadow> get shadowGlass => [
    BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.5) : const Color(0x12000000), blurRadius: 30, offset: const Offset(0, 12), spreadRadius: -4),
    BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.3) : const Color(0x08000000), blurRadius: 8, offset: const Offset(0, 4)),
    BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.15) : const Color(0x04000000), blurRadius: 2, offset: const Offset(0, 1)),
  ];
  List<BoxShadow> get shadowCard => [
    BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.3) : const Color(0x06000000), blurRadius: 12, offset: const Offset(0, 4)),
    BoxShadow(color: const Color(0x04000000), blurRadius: 2, offset: const Offset(0, 1)),
  ];

  // ── Bubble legacy compat ──
  Color get bubbleAssistant => bgCard;
  Color get bubbleUser => accent;
  Color get accentPurple => const Color(0xFFAF52DE);
}

// ── Riverpod bridge ──
final themeProvider = ChangeNotifierProvider<ThemeNotifier>((ref) => ThemeNotifier());

ThemeData buildAppTheme(ThemeState state) {
  final d = state.brightness == Brightness.dark;
  final textColor = d ? Colors.white : const Color(0xFF1C1C1E);
  return ThemeData(
    useMaterial3: true, brightness: state.brightness, colorSchemeSeed: state.accent,
    scaffoldBackgroundColor: d ? const Color(0xFF0D0D12) : const Color(0xFFF0EFF4),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: textColor, fontSize: 16),
      bodyMedium: TextStyle(color: textColor, fontSize: 14),
      bodySmall: TextStyle(color: textColor, fontSize: 12),
      titleMedium: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: textColor)),
    cardTheme: CardThemeData(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: d ? const Color(0xFF1A1A24) : Colors.white, surfaceTintColor: Colors.transparent),
  );
}
