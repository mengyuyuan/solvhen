/// Dynamic theme — singleton ChangeNotifier + Riverpod bridge.
import 'dart:ui' show Brightness;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/database_service.dart' show DB;

/// Global singleton — tools can call directly
class ThemeNotifier extends ChangeNotifier {
  static final ThemeNotifier _instance = ThemeNotifier._();
  factory ThemeNotifier() => _instance;
  ThemeNotifier._();

  ThemeState _state = const ThemeState();
  ThemeState get state => _state;
  bool _loaded = false;

  /// Call once after DB is ready to restore saved theme.
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
          brightness: brightnessStr == 'dark' ? Brightness.dark : Brightness.light,
        );
        notifyListeners();
      }
      _loaded = true;
    } catch (_) {
      // DB not ready yet — use defaults
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
      _state = ThemeState(accent: c, accentHex: hex, brightness: _state.brightness);
      notifyListeners();
      _persist();
      return true;
    } catch (_) { return false; }
  }

  void setBrightness(String mode) {
    _state = ThemeState(
      accent: _state.accent, accentHex: _state.accentHex,
      brightness: mode == 'dark' ? Brightness.dark : Brightness.light,
    );
    notifyListeners();
    _persist();
  }

  void _persist() {
    DB.setConfig('theme_accent', _state.accentHex).catchError((e) {
      debugPrint('Theme persist accent failed: $e');
    });
    DB.setConfig('theme_brightness', _state.brightness == Brightness.dark ? 'dark' : 'light').catchError((e) {
      debugPrint('Theme persist brightness failed: $e');
    });
  }

  static String? _resolve(String s) {
    final t = s.trim().toLowerCase();
    if (RegExp(r'^#?[0-9a-f]{6}$').hasMatch(t)) return t.startsWith('#') ? t : '#$t';
    const map = {
      'blue': '#007AFF', 'purple': '#AF52DE', 'green': '#34C759',
      'pink': '#FF2D55', 'orange': '#FF9500', 'red': '#FF3B30',
      'teal': '#5AC8FA', 'mint': '#34C759', 'yellow': '#FFCC00',
      'hot pink': '#FF69B4', 'hotpink': '#FF69B4', 'deeppink': '#FF1493',
      'cyan': '#00BCD4', 'indigo': '#5856D6', 'coral': '#FF6B6B',
      'black': '#1C1C1E', 'white': '#FFFFFF', 'grey': '#8E8E93', 'gray': '#8E8E93',
      'navy': '#001F3F', 'gold': '#FFD700', 'lavender': '#E6E6FA',
      'rose': '#FF007F', 'violet': '#8B5CF6', 'emerald': '#10B981',
      'sky': '#38BDF8', 'magenta': '#FF00FF',
    };
    return map[t];
  }
}

class ThemeState {
  final Color accent;
  final String accentHex;
  final Brightness brightness;
  const ThemeState({
    this.accent = const Color(0xFF007AFF),
    this.accentHex = '#007AFF',
    this.brightness = Brightness.light,
  });
}

/// Colors adapter — accepts ThemeNotifier
class ThemeColors {
  final ThemeNotifier _n;
  
  ThemeColors(ThemeNotifier notifier) : _n = notifier;

  ThemeState get s => _n.state;

  Color get accent => s.accent;

  // Precomputed colors — avoid Color.lerp on every access
  Color? _cachedBgRoot;
  Color? _cachedBgCardSolid;
  Brightness? _cachedBrightness;
  Color? _cachedAccent;

  void _invalidateCache() {
    final cs = s;
    if (_cachedBrightness != cs.brightness || _cachedAccent != cs.accent) {
      _cachedBgRoot = null;
      _cachedBgCardSolid = null;
      _cachedBrightness = cs.brightness;
      _cachedAccent = cs.accent;
    }
  }

  Color get bgRoot {
    _invalidateCache();
    _cachedBgRoot ??= Color.lerp(
      s.brightness == Brightness.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
      accent, 0.03,
    )!;
    return _cachedBgRoot!;
  }

  Color get bgCardSolid {
    _invalidateCache();
    _cachedBgCardSolid ??= Color.lerp(
      s.brightness == Brightness.dark ? const Color(0xFF2C2C2E) : Colors.white,
      accent, 0.02,
    )!;
    return _cachedBgCardSolid!;
  }
  
  // Solvhen's bubble background — subtle accent warmth
  Color get bubbleAssistant => bgCardSolid;
  
  // User's bubble — full accent
  Color get bubbleUser => accent;
  Color get textPrimary => s.brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1C1E);
  Color get textSecondary => const Color(0xFF8E8E93);
  Color get textTertiary => const Color(0xFFAEAEB2);
  Color get textPlaceholder => const Color(0xFFC7C7CC);
  Color get separator => s.brightness == Brightness.dark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
  Color get accentPurple => const Color(0xFFAF52DE);
  List<BoxShadow> get shadowSm => [BoxShadow(color: s.brightness == Brightness.dark ? Colors.black.withValues(alpha: 0.3) : const Color(0x0A000000), blurRadius: 8, offset: const Offset(0, 2))];
}

/// Riverpod bridge
final themeProvider = ChangeNotifierProvider<ThemeNotifier>((ref) => ThemeNotifier());

ThemeData buildAppTheme(ThemeState state) {
  final d = state.brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true, brightness: state.brightness, colorSchemeSeed: state.accent,
    scaffoldBackgroundColor: d ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
    appBarTheme: AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: d ? Colors.white : const Color(0xFF1C1C1E))),
    cardTheme: CardThemeData(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: d ? const Color(0xFF2C2C2E) : Colors.white, surfaceTintColor: Colors.transparent),
  );
}
