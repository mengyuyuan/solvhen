// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 工具通用工具函数——颜色解析/参数提取/结果格式化
// ═══════════════════════════════════════════════════════════════

///
/// Use these instead of bare `as T` casts on `args` values — the LLM
/// may pass strings for ints, ints for bools, or any unexpected type,
/// especially when tool calls arrive via DeepSeek XML mode.
library tool_utils;

/// Parse a dynamic value to int safely.
/// Handles int, double, String, and num types.
int parseArgInt(dynamic v, int fallback) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  if (v is num) return v.round();
  return fallback;
}

/// Parse a dynamic value to int or null.
int? parseArgOptionalInt(dynamic v) {
  if (v == null) return null;
  return parseArgInt(v, 0);
}

/// Parse a dynamic value to double safely.
double parseArgDouble(dynamic v, double fallback) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

/// Parse a dynamic value to bool safely.
/// Accepts: true, "true" (case-insensitive), 1, "1", "yes", "on"
bool parseArgBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'on';
  }
  return fallback;
}

/// Parse a dynamic value to String safely.
String parseArgString(dynamic v, [String fallback = '']) {
  if (v is String) return v;
  if (v != null) return v.toString();
  return fallback;
}

/// Parse a dynamic value to List safely.
List<dynamic> parseArgList(dynamic v) {
  if (v is List) return v;
  return <dynamic>[];
}

/// Parse a dynamic value to Map<String, dynamic> safely.
Map<String, dynamic> parseArgMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return <String, dynamic>{};
}

/// Clamp an int value to [min,max] inclusive.
int clampInt(int v, int min, int max) => v.clamp(min, max);
