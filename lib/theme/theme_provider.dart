// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 主题管理器——动态主题状态管理，玻璃态/暗色/亮色主题切换+颜色系统
// ═══════════════════════════════════════════════════════════════

library;

/// Solvhen dot-tech aesthetic: warm paper surfaces, restrained glass and
/// petrol-blue typography. Pure black is intentionally excluded from the
/// product palette so the interface stays calm during long agent runs.
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
        _state = ThemeState(
            accent: c,
            accentHex: accentHex,
            brightness:
                brightnessStr == 'dark' ? Brightness.dark : Brightness.light);
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _loaded = true;
    }
  }

  bool setAccentColor(String hexOrName) {
    final hex = _resolve(hexOrName);
    if (hex == null) return false;
    try {
      final h = hex.replaceFirst('#', '');
      final c = h.length == 8
          ? Color(int.parse(h, radix: 16))
          : Color(int.parse(h, radix: 16) | 0xFF000000);
      _state =
          ThemeState(accent: c, accentHex: hex, brightness: _state.brightness);
      notifyListeners();
      _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  void setBrightness(String mode) {
    _state = ThemeState(
        accent: _state.accent,
        accentHex: _state.accentHex,
        brightness: mode == 'dark' ? Brightness.dark : Brightness.light);
    notifyListeners();
    _persist();
  }

  void _persist() {
    DB
        .setConfig('theme_accent', _state.accentHex)
        .catchError((e) => debugPrint('Theme persist: $e'));
    DB
        .setConfig('theme_brightness',
            _state.brightness == Brightness.dark ? 'dark' : 'light')
        .catchError((e) => debugPrint('Theme persist: $e'));
  }

  static String? _resolve(String s) {
    final t = s.trim().toLowerCase();
    if (RegExp(r'^#?[0-9a-f]{6}$').hasMatch(t)) {
      return t.startsWith('#') ? t : '#$t';
    }
    const map = {
      'blue': '#007AFF',
      'purple': '#AF52DE',
      'green': '#34C759',
      'pink': '#FF2D55',
      'orange': '#FF9500',
      'red': '#D86161',
      'teal': '#1BA6A2',
      'mint': '#47B99F',
      'yellow': '#D9A441',
      'hotpink': '#D95D92',
      'cyan': '#38AFC0',
      'indigo': '#6875D8',
      'coral': '#D9786D',
      'black': '#24404D',
      'white': '#FFFFFF',
      'grey': '#8E8E93',
      'gray': '#8E8E93',
      'navy': '#001F3F',
      'gold': '#FFD700',
      'lavender': '#E6E6FA',
      'rose': '#FF007F',
      'violet': '#8B5CF6',
      'emerald': '#10B981',
      'sky': '#38BDF8',
      'magenta': '#FF00FF',
    };
    return map[t];
  }
}

class ThemeState {
  final Color accent;
  final String accentHex;
  final Brightness brightness;
  const ThemeState({
    this.accent = const Color(0xFF1BA6A2),
    this.accentHex = '#1BA6A2',
    this.brightness = Brightness.light,
  });
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
  Brightness? _cBr;
  Color? _cAc;

  void _inv() {
    if (_cBr != s.brightness || _cAc != s.accent) {
      _cBg = null;
      _cCard = null;
      _cHover = null;
      _cBr = s.brightness;
      _cAc = s.accent;
    }
  }

  // ── Backgrounds ──
  Color get bgRoot {
    _inv();
    _cBg ??= isDark ? const Color(0xFF102A35) : const Color(0xFFF7F6F1);
    return _cBg!;
  }

  Color get bgCard {
    _inv();
    _cCard ??= isDark ? const Color(0xFF183A47) : const Color(0xFFFFFEFB);
    return _cCard!;
  }

  // Legacy compat
  Color get bgCardSolid => bgCard;
  List<BoxShadow> get shadowSm => shadowCard;

  Color get navy => isDark ? const Color(0xFFAFC6F4) : const Color(0xFF244684);
  Color get accentSoft => Color.alphaBlend(
        accent.withValues(alpha: isDark ? 0.20 : 0.11),
        bgCard,
      );
  Color get accentFaint => Color.alphaBlend(
        accent.withValues(alpha: isDark ? 0.11 : 0.055),
        bgRoot,
      );
  Color get dotColor => isDark
      ? const Color(0xFF73C9C3).withValues(alpha: 0.30)
      : const Color(0xFF2A9D98).withValues(alpha: 0.24);

  // Glass panel — translucent frosted surface (use with BackdropFilter)
  Color get glassBg => isDark
      ? const Color(0xFF244653).withValues(alpha: 0.88)
      : const Color(0xFFFFFEFB).withValues(alpha: 0.91);
  Color get glassBorder =>
      isDark ? const Color(0xFF41616C) : const Color(0xFFDDE9E7);
  Color get glassHover {
    _inv();
    _cHover ??= isDark ? const Color(0xFF2A505C) : accentSoft;
    return _cHover!;
  }

  // Gradient wash — solid, clean ambient
  LinearGradient get bgGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: isDark
            ? [
                const Color(0xFF183D4A),
                const Color(0xFF102A35),
                const Color(0xFF122F3A)
              ]
            : [
                const Color(0xFFFFFEFB),
                const Color(0xFFF7F6F1),
                const Color(0xFFEFF6F3)
              ],
      );

  // Accent gradient for buttons/badges
  LinearGradient get accentGradient => LinearGradient(
        colors: [accent, accent.withValues(alpha: 0.75)],
      );

  // ── Text ──
  Color get textPrimary =>
      isDark ? const Color(0xFFF0F7F5) : const Color(0xFF173A4A);
  Color get textSecondary =>
      isDark ? const Color(0xFFB3C8CD) : const Color(0xFF526D79);
  Color get textTertiary =>
      isDark ? const Color(0xFF819DA5) : const Color(0xFF7E949D);
  Color get textPlaceholder =>
      isDark ? const Color(0xFF6D8992) : const Color(0xFFA6B6BC);
  Color get textCaption =>
      isDark ? const Color(0xFF91AAB1) : const Color(0xFF718A94);

  // ── Semantic ──
  Color get danger => const Color(0xFFD86161);
  Color get warning => const Color(0xFFC9823D);
  Color get success => const Color(0xFF2B9A87);
  Color get separator =>
      isDark ? const Color(0xFF355560) : const Color(0xFFDDE7E6);
  Color get scrim =>
      const Color(0xFF173A4A).withValues(alpha: isDark ? 0.68 : 0.46);

  // ── Shadows (glass multi-layer) ──
  List<BoxShadow> get shadowGlass => [
        BoxShadow(
            color:
                const Color(0xFF173A4A).withValues(alpha: isDark ? 0.28 : 0.10),
            blurRadius: 28,
            offset: const Offset(0, 12),
            spreadRadius: -5),
        BoxShadow(
            color: const Color(0xFF2A5661)
                .withValues(alpha: isDark ? 0.18 : 0.055),
            blurRadius: 8,
            offset: const Offset(0, 3)),
      ];
  List<BoxShadow> get shadowCard => [
        BoxShadow(
            color:
                const Color(0xFF234A56).withValues(alpha: isDark ? 0.20 : 0.07),
            blurRadius: 14,
            offset: const Offset(0, 5),
            spreadRadius: -3),
      ];

  // ── Bubble legacy compat ──
  Color get bubbleAssistant => bgCard;
  Color get bubbleUser =>
      Color.alphaBlend(accent.withValues(alpha: isDark ? 0.22 : 0.12), bgCard);
  Color get accentPurple => const Color(0xFF6875D8);
}

// ── Riverpod bridge ──
final themeProvider =
    ChangeNotifierProvider<ThemeNotifier>((ref) => ThemeNotifier());

ThemeData buildAppTheme(ThemeState state) {
  final d = state.brightness == Brightness.dark;
  final textColor = d ? const Color(0xFFF0F7F5) : const Color(0xFF173A4A);
  final secondaryText = d ? const Color(0xFFB3C8CD) : const Color(0xFF526D79);
  final root = d ? const Color(0xFF102A35) : const Color(0xFFF7F6F1);
  final surface = d ? const Color(0xFF183A47) : const Color(0xFFFFFEFB);
  final border = d ? const Color(0xFF355560) : const Color(0xFFDDE7E6);
  final scheme = ColorScheme.fromSeed(
    seedColor: state.accent,
    brightness: state.brightness,
  ).copyWith(
    primary: state.accent,
    onPrimary: Colors.white,
    surface: surface,
    onSurface: textColor,
    error: const Color(0xFFD86161),
    onError: Colors.white,
    outline: border,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: state.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: root,
    splashColor: state.accent.withValues(alpha: 0.08),
    highlightColor: state.accent.withValues(alpha: 0.04),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: textColor, fontSize: 16, height: 1.45),
      bodyMedium: TextStyle(color: textColor, fontSize: 14, height: 1.45),
      bodySmall: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
      titleLarge: TextStyle(
          color: textColor,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2),
      titleMedium: TextStyle(
          color: textColor, fontSize: 16, fontWeight: FontWeight.w600),
      labelLarge: TextStyle(
          color: textColor, fontSize: 14, fontWeight: FontWeight.w600),
    ),
    iconTheme: IconThemeData(color: secondaryText),
    appBarTheme: AppBarTheme(
      backgroundColor: surface.withValues(alpha: d ? 0.94 : 0.96),
      foregroundColor: textColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: secondaryText),
      titleTextStyle: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: textColor),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: border, width: 0.8),
      ),
      color: surface.withValues(alpha: d ? 0.92 : 0.94),
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: d ? const Color(0xFF214451) : const Color(0xFFFFFEFB),
      hintStyle: TextStyle(
          color: d ? const Color(0xFF78949C) : const Color(0xFFA6B6BC)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: state.accent, width: 1.2)),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 0.8, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: border)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: state.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textColor,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
  );
}
